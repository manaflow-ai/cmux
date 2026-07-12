import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal surface mutation invalidation")
struct TerminalSurfaceMutationInvalidationTests {
    @Test("idle composite queue yields its first local scroll")
    func idleCompositeQueueYieldsScroll() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "idle-scroll"
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        _ = store.mountTerminalScrollSession(surfaceID: surfaceID, cancelLocal: {})

        store.scrollTerminal(surfaceID: surfaceID, lines: -5, col: 2, row: 3)

        let chunk = try #require(await iterator.next())
        guard case .localScroll(let runs) = chunk.mutation else {
            Issue.record("expected an idle local scroll mutation")
            return
        }
        #expect(runs.map(\.lines) == [-5])
        #expect(store.terminalOutputWillProcess(
            surfaceID: surfaceID,
            streamToken: chunk.streamToken,
            deliveryID: chunk.deliveryID
        ))
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)
    }

    @Test("optimistic scroll skips stale viewport but preserves causal barriers")
    func atomicInvalidationPreservesRequiredOutput() throws {
        var queue = TerminalOutputDeliveryQueue()
        let staleFrame = try frame(text: "stale", full: true)
        let incrementalFrame = try frame(text: "incremental", full: false)
        let staleViewport = TerminalOutputDelivery(renderGrid: staleFrame, replaceable: true)
        let raw = TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false)
        let laterStaleViewport = TerminalOutputDelivery(renderGrid: staleFrame, replaceable: true)
        let incremental = TerminalOutputDelivery(renderGrid: incrementalFrame, replaceable: false)
        let policy = TerminalOutputDelivery(
            bytes: Data(),
            replaceable: true,
            replacementScope: .viewportPolicy,
            viewportPolicy: .natural
        )
        let barrier = TerminalOutputDelivery(barrierReceipt: TerminalSurfaceMutationReceipt())
        let scroll = TerminalOutputDelivery(
            localScroll: [MobileTerminalScrollRun(lines: -3, col: 1, row: 1)],
            receipt: TerminalSurfaceMutationReceipt()
        )

        #expect(queue.enqueue(staleViewport) == staleViewport)
        #expect(queue.enqueue(raw) == nil)
        #expect(queue.enqueue(laterStaleViewport) == nil)
        #expect(queue.enqueue(incremental) == nil)
        #expect(queue.enqueue(policy) == nil)
        #expect(queue.enqueue(barrier) == nil)

        let result = queue.enqueueOptimisticScroll(scroll)

        #expect(result.immediate == raw)
        #expect(queue.completeInFlight() == incremental)
        #expect(queue.completeInFlight() == policy)
        #expect(queue.completeInFlight() == barrier)
        #expect(queue.completeInFlight() == scroll)
    }

    @Test("claimed viewport remains ahead of optimistic scroll")
    func claimedViewportIsPreserved() throws {
        var queue = TerminalOutputDeliveryQueue()
        let viewport = TerminalOutputDelivery(
            renderGrid: try frame(text: "claimed", full: true),
            replaceable: true
        )
        let raw = TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false)
        let scroll = TerminalOutputDelivery(
            localScroll: [MobileTerminalScrollRun(lines: 2, col: 1, row: 1)],
            receipt: TerminalSurfaceMutationReceipt()
        )
        #expect(queue.enqueue(viewport) == viewport)
        let claimed = queue.claimInFlight(deliveryID: viewport.deliveryID)
        #expect(claimed)
        #expect(queue.enqueue(raw) == nil)

        let result = queue.enqueueOptimisticScroll(scroll)

        #expect(result.immediate == nil)
        #expect(queue.currentInFlight == viewport)
        #expect(queue.completeInFlight() == raw)
        #expect(queue.completeInFlight() == scroll)
    }

    @Test("rapid adjacent scrolls share one bounded batch receipt")
    func rapidScrollsShareReceipt() throws {
        var queue = TerminalOutputDeliveryQueue()
        let raw = TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false)
        #expect(queue.enqueue(raw) == raw)

        var sharedReceipt: TerminalSurfaceMutationReceipt?
        for _ in 0..<1_000 {
            let candidate = TerminalSurfaceMutationReceipt()
            let result = queue.enqueueOptimisticScroll(TerminalOutputDelivery(
                localScroll: [MobileTerminalScrollRun(lines: -1, col: 2, row: 3)],
                receipt: candidate
            ))
            if let sharedReceipt {
                #expect(result.receipt === sharedReceipt)
            } else {
                sharedReceipt = result.receipt
            }
        }

        #expect(queue.pendingCount == 1)
        let promoted = queue.completeInFlight()
        let batch = try #require(promoted)
        guard case .localScroll(let runs) = batch.mutation else {
            Issue.record("expected a coalesced local scroll batch")
            return
        }
        #expect(runs.count == 1)
        #expect(runs[0].lines == -1_000)
    }

    @Test("composite coalesces rapid local admission into one receipt entry")
    func compositeCoalescesRapidLocalAdmission() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "rapid-scroll"
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        _ = store.mountTerminalScrollSession(surfaceID: surfaceID, cancelLocal: {})
        store.deliverTerminalBytes(Data("head".utf8), surfaceID: surfaceID)

        for _ in 0..<100 {
            store.scrollTerminal(surfaceID: surfaceID, lines: -1, col: 2, row: 3)
        }

        #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 1)
        #expect(store.terminalScrollSessionsBySurfaceID[surfaceID]?.localPending.count == 0)
        #expect(store.terminalScrollSessionsBySurfaceID[surfaceID]?.latestClientRevision == 100)

        let head = try #require(await iterator.next())
        #expect(store.terminalOutputWillProcess(
            surfaceID: surfaceID,
            streamToken: head.streamToken,
            deliveryID: head.deliveryID
        ))
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: head.streamToken)
        let scroll = try #require(await iterator.next())
        guard case .localScroll(let runs) = scroll.mutation else {
            Issue.record("expected coalesced composite scroll")
            return
        }
        #expect(runs.count == 1)
        #expect(runs[0].lines == -100)
    }

    @Test("interaction batch cap rejects and reset resolves all receipts")
    func interactionCapRejectsAndResetResolvesReceipts() async {
        var queue = TerminalOutputDeliveryQueue()
        _ = queue.enqueue(TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false))
        let fullBatch = (0..<TerminalScrollRequest.maximumJournalRunCount).map { index in
            MobileTerminalScrollRun(
                lines: index.isMultiple(of: 2) ? -1 : 1,
                col: index,
                row: index
            )
        }
        var retainedReceipts: [TerminalSurfaceMutationReceipt] = []
        for _ in 0..<TerminalScrollSession.maximumQueuedInteractionCount {
            let receipt = TerminalSurfaceMutationReceipt()
            retainedReceipts.append(queue.enqueueOptimisticScroll(TerminalOutputDelivery(
                localScroll: fullBatch,
                receipt: receipt
            )).receipt)
        }
        let rejected = TerminalSurfaceMutationReceipt()
        _ = queue.enqueueOptimisticScroll(TerminalOutputDelivery(
            localScroll: fullBatch,
            receipt: rejected
        ))

        #expect(await rejected.value == false)
        queue.reset()
        for receipt in retainedReceipts {
            #expect(await receipt.value == false)
        }
    }

    @Test("input snap stays behind admitted scroll and ahead of later output")
    func inputSnapUsesCausalStream() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "input-snap"
        var momentumCancellationCount = 0
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        _ = store.mountTerminalScrollSession(surfaceID: surfaceID) {
            momentumCancellationCount += 1
        }
        store.deliverTerminalBytes(Data("before".utf8), surfaceID: surfaceID)
        store.scrollTerminal(surfaceID: surfaceID, lines: -4, col: 1, row: 2)
        let firstInputEpoch = store.invalidateTerminalScrollForInput(surfaceID: surfaceID)
        let secondInputEpoch = store.invalidateTerminalScrollForInput(surfaceID: surfaceID)
        store.deliverTerminalBytes(Data("after".utf8), surfaceID: surfaceID)

        #expect(firstInputEpoch != secondInputEpoch)
        #expect(momentumCancellationCount == 2)

        var mutations: [MobileTerminalSurfaceMutation] = []
        for _ in 0..<4 {
            let chunk = try #require(await iterator.next())
            mutations.append(chunk.mutation)
            #expect(store.terminalOutputWillProcess(
                surfaceID: surfaceID,
                streamToken: chunk.streamToken,
                deliveryID: chunk.deliveryID
            ))
            store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)
        }

        guard case .output(let before) = mutations[0],
              case .localScroll = mutations[1],
              case .scrollToBottom = mutations[2],
              case .output(let after) = mutations[3] else {
            Issue.record("unexpected input snap mutation order")
            return
        }
        #expect(String(decoding: before.data, as: UTF8.self) == "before")
        #expect(String(decoding: after.data, as: UTF8.self) == "after")
    }

    @Test("input retires an unclaimed reconciliation from the previous epoch")
    func inputRetiresUnclaimedReconciliation() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "unclaimed-reconciliation"
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        _ = store.mountTerminalScrollSession(surfaceID: surfaceID, cancelLocal: {})
        let oldEpoch = try #require(store.currentTerminalInteractionEpoch(surfaceID: surfaceID))
        let reconciliation = try reconciliationFrame(surfaceID: surfaceID)
        #expect(store.deliverAuthoritativeTerminalRenderGrid(
            reconciliation,
            source: "scroll_reconcile",
            scrollReconciliation: TerminalScrollReconciliation(
                interactionEpoch: oldEpoch,
                clientRevision: 1
            )
        ))
        let stale = try #require(await iterator.next())

        let newEpoch = try #require(store.invalidateTerminalScrollForInput(surfaceID: surfaceID))
        let staleClaimed = store.terminalOutputWillProcess(
            surfaceID: surfaceID,
            streamToken: stale.streamToken,
            deliveryID: stale.deliveryID
        )

        #expect(newEpoch != oldEpoch)
        #expect(!staleClaimed)
        guard !staleClaimed else { return }
        let bottom = try #require(await iterator.next())
        #expect(bottom.mutation == .scrollToBottom)
    }

    @Test("input forces replay recovery when an old reconciliation is claimed")
    func inputRecoversClaimedReconciliation() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "claimed-reconciliation"
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        _ = store.mountTerminalScrollSession(surfaceID: surfaceID, cancelLocal: {})
        let oldEpoch = try #require(store.currentTerminalInteractionEpoch(surfaceID: surfaceID))
        let reconciliation = try reconciliationFrame(surfaceID: surfaceID)
        #expect(store.deliverAuthoritativeTerminalRenderGrid(
            reconciliation,
            source: "scroll_reconcile",
            scrollReconciliation: TerminalScrollReconciliation(
                interactionEpoch: oldEpoch,
                clientRevision: 1
            )
        ))
        let claimed = try #require(await iterator.next())
        #expect(store.terminalOutputWillProcess(
            surfaceID: surfaceID,
            streamToken: claimed.streamToken,
            deliveryID: claimed.deliveryID
        ))

        _ = store.invalidateTerminalScrollForInput(surfaceID: surfaceID)

        #expect(store.terminalOutputStreamTokensBySurfaceID[surfaceID] != claimed.streamToken)
    }

    @Test("input retires pending reconciliations behind claimed output")
    func inputRetiresPendingReconciliations() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "pending-reconciliations"
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        _ = store.mountTerminalScrollSession(surfaceID: surfaceID, cancelLocal: {})
        let oldEpoch = try #require(store.currentTerminalInteractionEpoch(surfaceID: surfaceID))
        store.deliverTerminalBytes(Data("claimed".utf8), surfaceID: surfaceID)
        let claimed = try #require(await iterator.next())
        #expect(store.terminalOutputWillProcess(
            surfaceID: surfaceID,
            streamToken: claimed.streamToken,
            deliveryID: claimed.deliveryID
        ))
        for revision in 1...2 {
            #expect(store.deliverAuthoritativeTerminalRenderGrid(
                try reconciliationFrame(surfaceID: surfaceID, renderRevision: UInt64(revision)),
                source: "scroll_reconcile",
                scrollReconciliation: TerminalScrollReconciliation(
                    interactionEpoch: oldEpoch,
                    clientRevision: UInt64(revision)
                )
            ))
        }

        _ = store.invalidateTerminalScrollForInput(surfaceID: surfaceID)
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: claimed.streamToken)

        let bottom = try #require(await iterator.next())
        #expect(bottom.mutation == .scrollToBottom)
    }

    private func frame(text: String, full: Bool) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "terminal",
            stateSeq: 1,
            columns: 16,
            rows: 2,
            text: "\(text)\nrow",
            full: full,
            changedRows: full ? nil : [0]
        )
    }

    private func reconciliationFrame(
        surfaceID: String,
        renderRevision: UInt64 = 1
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: surfaceID,
            stateSeq: 10,
            renderRevision: renderRevision,
            columns: 16,
            rows: 2,
            text: "authoritative\nviewport"
        )
    }
}
