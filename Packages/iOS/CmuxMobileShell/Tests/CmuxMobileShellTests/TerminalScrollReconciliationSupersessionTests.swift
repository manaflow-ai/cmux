import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal scroll reconciliation supersession")
struct TerminalScrollReconciliationSupersessionTests {
    @Test("rolling authoritative frame lands and reapplies already optimistic rows")
    func rollingAuthoritativeFrameReappliesOptimisticRows() async throws {
        let harness = ScrollReconciliationSupersessionHarness()
        let session = harness.makeSession()

        session.submit(lines: -4, col: 1, row: 2)
        try await requireEventually { harness.remoteScrolls.count == 1 }
        harness.completeCurrentDelivery()
        try await requireEventually { session.latestLocallyAppliedRevision == 1 }

        harness.enqueueClaimedRawBlocker()
        let firstRemote = harness.remoteScrolls[0]
        session.submit(lines: -7, col: 3, row: 4)
        #expect(harness.queue.pendingCount == 1)
        firstRemote.continuation.resume(returning: harness.response(for: firstRemote.request))
        try await requireEventually {
            if case .scroll(let transaction) = session.phase {
                return transaction.awaitingAuthoritative && harness.queue.pendingCount == 2
            }
            return false
        }

        #expect(harness.remoteScrolls.count == 1)

        let next = try #require(harness.completeCurrentDelivery())
        guard case .localScroll(let runs) = next.mutation else {
            Issue.record("Expected the newer optimistic scroll after the blocker")
            return
        }
        #expect(runs.map(\.lines) == [-7])
        let reconciliation = try #require(harness.completeCurrentDelivery())
        guard case .output(let operation) = reconciliation.mutation else {
            Issue.record("Expected the rolling authoritative frame after optimistic input")
            return
        }
        #expect(operation.followingScrollRuns.map(\.lines) == [-7])
        harness.completeCurrentDelivery()

        try await requireEventually { harness.remoteScrolls.count == 2 }
        #expect(harness.superseded.isEmpty)
        #expect(harness.replayEpochs.isEmpty)
        #expect(harness.remoteScrolls.map(\.request.lines) == [-4, -7])

        session.cancelForUnmount(nextEpoch: 2)
        harness.remoteScrolls[1].continuation.resume(returning: nil)
    }

    private func requireEventually(_ condition: @MainActor () async -> Bool) async throws {
        try #require(await pollUntil(condition))
    }
}

@MainActor
private final class ScrollReconciliationSupersessionHarness {
    struct PendingRemote {
        let request: TerminalScrollRequest
        let continuation: CheckedContinuation<TerminalScrollResponse?, Never>
    }

    var queue = TerminalOutputDeliveryQueue()
    var remoteScrolls: [PendingRemote] = []
    var superseded: [TerminalScrollReconciliationSupersession] = []
    var replayEpochs: [UInt64] = []
    weak var session: TerminalScrollSession?
    private let deadline = TerminalInteractionDeadlineSignal()
    private var epoch: UInt64 = 1

    func makeSession() -> TerminalScrollSession {
        let session = TerminalScrollSession(
            surfaceID: "surface-1",
            interactionEpoch: epoch,
            enqueueLocal: { [weak self] runs in
                guard let self else {
                    let receipt = TerminalSurfaceMutationReceipt()
                    receipt.resolve(false)
                    return receipt
                }
                let receipt = TerminalSurfaceMutationReceipt()
                _ = self.queue.enqueueOptimisticScroll(TerminalOutputDelivery(
                    localScroll: runs,
                    receipt: receipt
                ))
                self.acknowledgeSupersededReconciliations()
                return receipt
            },
            enqueueBarrier: { [self] in self.resolvedReceipt(true) },
            enqueueScrollToBottom: { [self] in self.resolvedReceipt(true) },
            cancelLocal: {},
            sendRemote: { [weak self] request in
                await withCheckedContinuation { continuation in
                    guard let self else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.remoteScrolls.append(PendingRemote(
                        request: request,
                        continuation: continuation
                    ))
                }
            },
            interactionDeadline: { [deadline] _ in await deadline.wait() },
            prepareIntent: {},
            deliverAuthoritative: { [weak self] renderGrid, interactionEpoch, clientRevision, followingRuns in
                guard let self else { return false }
                _ = queue.enqueue(TerminalOutputDelivery(
                    renderGrid: renderGrid.frame,
                    preparedBytes: renderGrid.bytes,
                    replaceable: true,
                    scrollReconciliation: TerminalScrollReconciliation(
                        interactionEpoch: interactionEpoch,
                        clientRevision: clientRevision
                    ),
                    followingScrollRuns: followingRuns
                ))
                acknowledgeSupersededReconciliations()
                return true
            },
            completeGridlessAuthoritative: { _ in true },
            reconciliationDidComplete: {},
            requestReplay: { [weak self] epoch in self?.replayEpochs.append(epoch) },
            advanceEpoch: { [weak self] in
                guard let self else { return 0 }
                epoch += 1
                return epoch
            }
        )
        self.session = session
        return session
    }

    func enqueueClaimedRawBlocker() {
        let blocker = queue.enqueue(TerminalOutputDelivery(
            bytes: Data("blocker".utf8),
            replaceable: false
        ))!
        let claimed = queue.claimInFlight(deliveryID: blocker.deliveryID)
        #expect(claimed)
    }

    @discardableResult
    func completeCurrentDelivery() -> TerminalOutputDelivery? {
        let completed = queue.currentInFlight
        let next = queue.completeInFlight()
        if let reconciliation = completed?.scrollReconciliation {
            session?.authoritativeDidApply(
                interactionEpoch: reconciliation.interactionEpoch,
                clientRevision: reconciliation.clientRevision
            )
        }
        acknowledgeSupersededReconciliations()
        return next
    }

    func response(for request: TerminalScrollRequest) -> TerminalScrollResponse {
        TerminalScrollResponse(
            accepted: true,
            interactionEpoch: request.interactionEpoch,
            clientRevision: request.clientRevision,
            renderRevision: request.clientRevision,
            renderGrid: try! MobileTerminalRenderGridFrame.fromPlainRows(
                surfaceID: request.surfaceID,
                stateSeq: request.clientRevision,
                renderRevision: request.clientRevision,
                columns: 20,
                rows: 2,
                text: "authoritative\nviewport"
            )
        )
    }

    private func acknowledgeSupersededReconciliations() {
        for supersession in queue.takeScrollReconciliationSupersessions() {
            superseded.append(supersession)
            session?.authoritativeReconciliationWasSuperseded(supersession)
        }
    }

    private func resolvedReceipt(_ applied: Bool) -> TerminalSurfaceMutationReceipt {
        let receipt = TerminalSurfaceMutationReceipt()
        receipt.resolve(applied)
        return receipt
    }
}
