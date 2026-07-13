import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal interaction lane")
struct TerminalInteractionLaneTests {
    @Test("production interaction deadline is synchronized at 200 milliseconds")
    func productionInteractionDeadlineIsBounded() {
        #expect(TerminalScrollSession.interactionDeadlineMilliseconds == 200)
        #expect(TerminalScrollSession.interactionDeadlineDuration == .milliseconds(200))
        #expect(TerminalScrollSession.interactionDeadlineDuration <= .milliseconds(200))
        #expect(TerminalRPCDeadlinePolicy.interaction.timeoutNanoseconds == 200_000_000)
        #expect(TerminalRPCDeadlinePolicy.input.timeoutNanoseconds == nil)
        #expect(
            TerminalRPCDeadlinePolicy.interaction.timeoutNanoseconds
                == TerminalScrollSession.interactionDeadlineMilliseconds * 1_000_000
        )
    }

    @Test("large input is not governed by the scroll deadline")
    func largeInputIgnoresScrollDeadline() async throws {
        let harness = InteractionLaneHarness()
        harness.holdInputs = true
        let session = harness.makeSession()
        let image = Data(repeating: 0xA5, count: 1_000_000)

        let receipt = session.submitInput(.image(image, format: "png", workspaceID: "workspace-1"))
        try await requireEventually { harness.remoteInputs.count == 1 }
        guard case .inputSend = session.phase else {
            Issue.record("Expected a dispatched input send")
            return
        }

        harness.deadline.fire()
        await Task.yield()

        #expect(harness.replayEpochs.isEmpty)
        guard case .inputSend = session.phase else {
            Issue.record("Scroll deadline must not end an input send")
            return
        }
        harness.remoteInputs[0].continuation.resume(returning: true)
        #expect(await receipt.value)
    }

    @Test("scroll deadline releases the newest live frame and requests replay")
    func scrollDeadlineReleasesDeferredFrame() async throws {
        let harness = InteractionLaneHarness()
        let session = harness.makeSession()

        session.submit(lines: -8, col: 2, row: 3)
        try await requireEventually {
            harness.remoteScrolls.count == 1 && harness.localReceipts.count == 1
        }
        harness.localReceipts[0].resolve(true)
        harness.deferredFrame = "latest-live-frame"

        harness.deadline.fire()

        try await requireEventually { harness.replayEpochs == [2] }
        #expect(harness.flushedFrames == ["latest-live-frame"])
        #expect(!session.shouldDeferLiveRenderGrid)
        #expect(session.interactionEpoch == 2)

        harness.remoteScrolls[0].continuation.resume(returning: nil)
    }

    @Test("click followed immediately by input preserves both in order")
    func clickThenInputPreservesBoth() async throws {
        let harness = InteractionLaneHarness()
        let session = harness.makeSession()

        session.submitClick(col: 4, row: 5)
        let inputReceipt = session.submitInput(.text("x", workspaceID: "workspace-1"))

        #expect(harness.events.isEmpty)
        #expect(harness.momentumCancellationCount == 1)
        let barrier = try #require(harness.barrierReceipts.first)
        barrier.resolve(true)
        try await requireEventually { harness.remoteClicks.count == 1 }
        #expect(harness.events == [.click(epoch: 2, col: 4, row: 5)])

        harness.remoteClicks[0].continuation.resume(returning: true)
        try await requireEventually { harness.events.count == 2 }

        #expect(harness.events == [
            .click(epoch: 2, col: 4, row: 5),
            .input(epoch: 3, text: "x"),
        ])
        #expect(harness.bottomSnapCount == 1)
        #expect(await inputReceipt.value)
    }

    @Test("scroll click and input burst remains causal")
    func scrollClickInputBurstRemainsCausal() async throws {
        let harness = InteractionLaneHarness()
        let session = harness.makeSession()

        session.submit(lines: -4, col: 1, row: 2)
        session.submitClick(col: 6, row: 7)
        let inputReceipt = session.submitInput(.text("q", workspaceID: "workspace-1"))

        try await requireEventually {
            harness.remoteScrolls.count == 1 && harness.localReceipts.count == 1
        }
        let scroll = harness.remoteScrolls[0]
        harness.localReceipts[0].resolve(true)
        scroll.continuation.resume(returning: harness.response(for: scroll.request))
        try await requireEventually { harness.deliveredReconciliations.count == 1 }
        session.authoritativeDidApply(interactionEpoch: 1, clientRevision: 1)

        try await requireEventually { harness.barrierReceipts.count == 1 }
        harness.barrierReceipts[0].resolve(true)
        try await requireEventually { harness.remoteClicks.count == 1 }
        harness.remoteClicks[0].continuation.resume(returning: true)
        try await requireEventually { harness.events.count == 3 }

        #expect(harness.events == [
            .scroll(epoch: 1, runs: [-4]),
            .click(epoch: 2, col: 6, row: 7),
            .input(epoch: 3, text: "q"),
        ])
        #expect(await inputReceipt.value)
    }

    @Test("unified intent overflow recovers and resolves queued input")
    func unifiedIntentOverflowRecovers() async {
        let harness = InteractionLaneHarness()
        let session = harness.makeSession()

        session.submitClick(col: 0, row: 0)
        var receipts: [TerminalInteractionReceipt] = []
        for index in 0..<TerminalScrollSession.maximumQueuedInteractionCount {
            receipts.append(session.submitInput(.text("\(index)", workspaceID: "workspace-1")))
        }
        #expect(harness.replayEpochs.isEmpty)

        let rejected = session.submitInput(.text("overflow", workspaceID: "workspace-1"))

        #expect(harness.replayEpochs == [2])
        #expect(await rejected.value == false)
        for receipt in receipts {
            #expect(await receipt.value == false)
        }
    }

    @Test("unmount cancels queued input without sending it")
    func unmountCancelsQueuedInput() async {
        let harness = InteractionLaneHarness()
        let session = harness.makeSession()

        session.submitClick(col: 1, row: 1)
        let inputReceipt = session.submitInput(.text("x", workspaceID: "workspace-1"))

        session.cancelForUnmount(nextEpoch: 2)

        #expect(await inputReceipt.value == false)
        #expect(harness.events.isEmpty)
    }

    @Test("opposite scroll runs retain order in one bounded transaction")
    func oppositeScrollRunsRetainOrder() async throws {
        let harness = InteractionLaneHarness()
        harness.supportsOrderedRuns = true
        let session = harness.makeSession()

        session.submit(lines: 5, col: 1, row: 1)
        session.submit(lines: -3, col: 2, row: 2)
        session.submit(lines: 2, col: 3, row: 3)

        try await requireEventually { harness.remoteScrolls.count == 1 }
        let first = harness.remoteScrolls[0]
        harness.localReceipts[0].resolve(true)
        first.continuation.resume(returning: harness.response(for: first.request))
        try await requireEventually { harness.remoteScrolls.count == 2 }
        #expect(harness.remoteScrolls[1].request.directionalRuns.map(\.lines) == [-3, 2])
        session.cancelForUnmount(nextEpoch: 2)
        harness.remoteScrolls[1].continuation.resume(returning: nil)
    }

    private func requireEventually(_ condition: @MainActor () async -> Bool) async throws {
        try #require(await pollUntil(condition))
    }
}

@MainActor
final class TerminalInteractionDeadlineSignal {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(id: id)
            }
        }
    }

    func fire() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    private func resolve(id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

@MainActor
private final class InteractionLaneHarness {
    enum Event: Equatable {
        case scroll(epoch: UInt64, runs: [Double])
        case click(epoch: UInt64, col: Int, row: Int)
        case input(epoch: UInt64, text: String)
    }

    struct PendingScroll {
        let request: TerminalScrollRequest
        let continuation: CheckedContinuation<TerminalScrollResponse?, Never>
    }

    struct PendingClick {
        let continuation: CheckedContinuation<Bool, Never>
    }

    struct PendingInput {
        let continuation: CheckedContinuation<Bool, Never>
    }

    let deadline = TerminalInteractionDeadlineSignal()
    var localReceipts: [TerminalSurfaceMutationReceipt] = []
    var barrierReceipts: [TerminalSurfaceMutationReceipt] = []
    var remoteScrolls: [PendingScroll] = []
    var remoteClicks: [PendingClick] = []
    var remoteInputs: [PendingInput] = []
    var events: [Event] = []
    var deliveredReconciliations: [(UInt64, UInt64)] = []
    var deferredFrame: String?
    var flushedFrames: [String] = []
    var replayEpochs: [UInt64] = []
    var bottomSnapCount = 0
    var momentumCancellationCount = 0
    var supportsOrderedRuns = false
    var holdInputs = false
    var epoch: UInt64 = 1

    func makeSession() -> TerminalScrollSession {
        TerminalScrollSession(
            surfaceID: "surface-1",
            interactionEpoch: epoch,
            enqueueLocal: { [weak self] _ in
                let receipt = TerminalSurfaceMutationReceipt()
                self?.localReceipts.append(receipt)
                return receipt
            },
            enqueueBarrier: { [weak self] in
                let receipt = TerminalSurfaceMutationReceipt()
                self?.barrierReceipts.append(receipt)
                return receipt
            },
            enqueueScrollToBottom: { [weak self] in
                self?.bottomSnapCount += 1
                let receipt = TerminalSurfaceMutationReceipt()
                receipt.resolve(true)
                return receipt
            },
            cancelLocal: { [weak self] in
                self?.momentumCancellationCount += 1
            },
            sendRemote: { [weak self] request in
                self?.events.append(.scroll(
                    epoch: request.interactionEpoch,
                    runs: request.directionalRuns.map(\.lines)
                ))
                return await withCheckedContinuation { continuation in
                    self?.remoteScrolls.append(PendingScroll(
                        request: request,
                        continuation: continuation
                    ))
                }
            },
            sendClick: { [weak self] _, epoch, col, row in
                self?.events.append(.click(epoch: epoch, col: col, row: row))
                return await withCheckedContinuation { continuation in
                    self?.remoteClicks.append(PendingClick(continuation: continuation))
                }
            },
            sendInput: { [weak self] _, epoch, input in
                if case .text(let text, _) = input {
                    self?.events.append(.input(epoch: epoch, text: text))
                }
                guard self?.holdInputs == true else { return true }
                return await withCheckedContinuation { continuation in
                    self?.remoteInputs.append(PendingInput(continuation: continuation))
                }
            },
            supportsOrderedRemoteRuns: { [weak self] in
                self?.supportsOrderedRuns == true
            },
            interactionDeadline: { [deadline] in
                await deadline.wait()
            },
            prepareIntent: {},
            deliverAuthoritative: { [weak self] _, epoch, revision in
                self?.deliveredReconciliations.append((epoch, revision))
                return true
            },
            completeGridlessAuthoritative: { _ in true },
            reconciliationDidComplete: { [weak self] in
                guard let frame = self?.deferredFrame else { return }
                self?.flushedFrames.append(frame)
                self?.deferredFrame = nil
            },
            requestReplay: { [weak self] epoch in
                self?.replayEpochs.append(epoch)
            },
            advanceEpoch: { [weak self] in
                guard let self else { return 0 }
                epoch += 1
                return epoch
            }
        )
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
}
