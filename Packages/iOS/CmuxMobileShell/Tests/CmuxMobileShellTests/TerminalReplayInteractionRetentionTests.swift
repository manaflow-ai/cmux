import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal replay interaction retention")
struct TerminalReplayInteractionRetentionTests {
    @Test("replay reset retains an unclaimed in-flight interaction")
    func unclaimedInFlightInteractionIsRetained() async throws {
        var queue = TerminalOutputDeliveryQueue()
        let receipt = TerminalSurfaceMutationReceipt()

        _ = queue.enqueue(TerminalOutputDelivery(scrollToBottomReceipt: receipt))
        queue.resetForReplayBarrier()

        let released = queue.releaseBarrierInteractions()
        let retained = try #require(released)
        #expect(retained.mutation == .scrollToBottom)
        _ = queue.completeInFlight()
        #expect(await receipt.value)
    }

    @Test("replay reset retains a pending interaction behind discarded output")
    func pendingInteractionBeforeBarrierIsRetained() async throws {
        var queue = TerminalOutputDeliveryQueue()
        let receipt = TerminalSurfaceMutationReceipt()

        _ = queue.enqueue(TerminalOutputDelivery(
            bytes: Data("stalled-output".utf8),
            replaceable: false
        ))
        _ = queue.enqueue(TerminalOutputDelivery(scrollToBottomReceipt: receipt))
        queue.resetForReplayBarrier()

        let released = queue.releaseBarrierInteractions()
        let retained = try #require(released)
        #expect(retained.mutation == .scrollToBottom)
        _ = queue.completeInFlight()
        #expect(await receipt.value)
    }

    @Test("live baseline bypass retains interactions admitted during a barrier")
    func liveBaselineBypassRetainsBarrierInteractions() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "live-baseline-interaction"
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let token = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
        store.terminalColdAttachReplayBarrierTokensBySurfaceID[surfaceID] = token
        let receipt = store.enqueueTerminalScrollToBottomMutation(surfaceID: surfaceID)

        let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: surfaceID,
            stateSeq: 10,
            columns: 16,
            rows: 2,
            text: "live baseline\nready",
            full: true
        )
        #expect(store.deliverAuthoritativeTerminalRenderGrid(frame, source: "event"))
        let baseline = try #require(await iterator.next())
        apply(baseline, store: store, surfaceID: surfaceID)

        let retainedReady = try await pollUntil(attempts: 5) {
            store.terminalOutputQueuesBySurfaceID[surfaceID]?.currentInFlight?.isInteractionMutation == true
        }
        #expect(retainedReady)
        guard retainedReady else { return }
        let retained = try #require(await iterator.next())
        #expect(retained.mutation == .scrollToBottom)
        apply(retained, store: store, surfaceID: surfaceID)
        #expect(await receipt.value)
    }

    @Test("claimed interaction completes once without replay duplication")
    func claimedInteractionIsAcknowledgedWithoutDuplicate() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "claimed-replay-interaction"
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let receipt = store.enqueueTerminalMutationBarrier(surfaceID: surfaceID)
        let claimed = try #require(await iterator.next())
        #expect(store.terminalOutputWillProcess(
            surfaceID: surfaceID,
            streamToken: claimed.streamToken,
            deliveryID: claimed.deliveryID
        ))

        _ = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
        #expect(store.deliverTerminalBytes(
            Data("authoritative-replay".utf8),
            surfaceID: surfaceID,
            bypassReplayBarrier: true
        ))
        let replay = try #require(await iterator.next())

        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: claimed.streamToken)
        apply(replay, store: store, surfaceID: surfaceID)

        #expect(await receipt.value)
        #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    }

    @Test("click then input snap survive replay in causal order without duplicates")
    func clickThenInputSnapRemainCausal() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "click-input-replay"
        let recorder = ReplayInteractionRecorder()
        let deadline = TerminalInteractionDeadlineSignal()
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let session = makeSession(
            store: store,
            surfaceID: surfaceID,
            recorder: recorder,
            deadline: deadline
        )

        session.submitClick(col: 4, row: 5)
        let clickBarrier = try #require(await iterator.next())
        let inputReceipt = session.submitInput(.text("x", workspaceID: "workspace-1"))
        _ = store.beginTerminalReplayBarrier(surfaceID: surfaceID)

        #expect(store.deliverTerminalBytes(
            Data("authoritative-replay".utf8),
            surfaceID: surfaceID,
            bypassReplayBarrier: true
        ))
        let replay = try #require(await iterator.next())
        apply(replay, store: store, surfaceID: surfaceID)

        let clickBarrierReady = try await pollUntil(attempts: 5) {
            store.terminalOutputQueuesBySurfaceID[surfaceID]?.currentInFlight?.isInteractionMutation == true
        }
        #expect(clickBarrierReady)
        guard clickBarrierReady else { return }
        let retainedClickBarrier = try #require(await iterator.next())
        #expect(retainedClickBarrier.mutation == .barrier)
        apply(retainedClickBarrier, store: store, surfaceID: surfaceID)
        #expect(try await pollUntil { recorder.events == [.click] })

        let bottomSnap = try #require(await iterator.next())
        #expect(bottomSnap.mutation == .scrollToBottom)
        apply(bottomSnap, store: store, surfaceID: surfaceID)
        #expect(await inputReceipt.value)

        #expect(recorder.events == [.click, .input])
        #expect(recorder.bottomSnapCount == 1)
        #expect(clickBarrier.deliveryID == retainedClickBarrier.deliveryID)
        #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    }

    private func apply(
        _ chunk: MobileTerminalOutputChunk,
        store: MobileShellComposite,
        surfaceID: String
    ) {
        #expect(store.terminalOutputWillProcess(
            surfaceID: surfaceID,
            streamToken: chunk.streamToken,
            deliveryID: chunk.deliveryID
        ))
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)
    }

    private func makeSession(
        store: MobileShellComposite,
        surfaceID: String,
        recorder: ReplayInteractionRecorder,
        deadline: TerminalInteractionDeadlineSignal
    ) -> TerminalScrollSession {
        TerminalScrollSession(
            surfaceID: surfaceID,
            interactionEpoch: 1,
            enqueueLocal: { runs in
                store.enqueueTerminalLocalScrollMutation(surfaceID: surfaceID, runs: runs)
            },
            enqueueBarrier: {
                store.enqueueTerminalMutationBarrier(surfaceID: surfaceID)
            },
            enqueueScrollToBottom: {
                recorder.bottomSnapCount += 1
                return store.enqueueTerminalScrollToBottomMutation(surfaceID: surfaceID)
            },
            cancelLocal: {},
            sendRemote: { _ in nil },
            sendClick: { _, _, _, _ in
                recorder.events.append(.click)
                return true
            },
            sendInput: { _, _, _ in
                recorder.events.append(.input)
                return true
            },
            interactionDeadline: { budget in
                await deadline.wait()
            },
            prepareIntent: {},
            deliverAuthoritative: { _, _, _, _ in true },
            completeGridlessAuthoritative: { _ in true },
            reconciliationDidComplete: {},
            requestReplay: { _ in },
            advanceEpoch: {
                recorder.epoch += 1
                return recorder.epoch
            }
        )
    }
}

@MainActor
private final class ReplayInteractionRecorder {
    enum Event: Equatable {
        case click
        case input
    }

    var events: [Event] = []
    var bottomSnapCount = 0
    var epoch: UInt64 = 1
}
