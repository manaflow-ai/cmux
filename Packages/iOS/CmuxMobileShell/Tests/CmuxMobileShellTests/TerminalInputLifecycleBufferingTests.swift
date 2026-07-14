import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal input lifecycle and buffering")
struct TerminalInputLifecycleBufferingTests {
    @Test("dispatched text paste and image inputs survive unmount exactly once")
    func dispatchedInputsSurviveUnmount() async throws {
        for input in LifecycleInputKind.allInputs {
            for result in [true, false] {
                let harness = InputBufferingHarness()
                let session = harness.makeSession()
                let receipt = session.submitInput(input)
                try await requireEventually { harness.pendingInputs.count == 1 }

                session.cancelForUnmount(nextEpoch: 2)
                guard case .inputSend = session.phase else {
                    Issue.record("Unmount cancelled an already-dispatched \(input.testName) input")
                    harness.pendingInputs[0].continuation.resume(returning: result)
                    continue
                }

                harness.pendingInputs[0].continuation.resume(returning: result)
                #expect(await receipt.value == result)
                #expect(harness.recordedInputs.count == 1)
                #expect(try await pollUntil { session.inputTask == nil })
                guard case .idle = session.phase else {
                    Issue.record("Completed \(input.testName) input did not clean up the session")
                    continue
                }
            }
        }
    }

    @Test("recovery preserves an already-dispatched input")
    func dispatchedInputSurvivesRecovery() async throws {
        let harness = InputBufferingHarness()
        let session = harness.makeSession()
        let receipt = session.submitInput(.text("x", workspaceID: "workspace-1"))
        try await requireEventually { harness.pendingInputs.count == 1 }

        _ = session.invalidateForRecovery()
        guard case .inputSend = session.phase else {
            Issue.record("Recovery cancelled an already-dispatched input")
            harness.pendingInputs[0].continuation.resume(returning: true)
            return
        }
        harness.pendingInputs[0].continuation.resume(returning: true)

        #expect(await receipt.value)
        #expect(harness.recordedInputs == [.text("x")])
        #expect(try await pollUntil { session.inputTask == nil })
    }

    @Test("key repeat coalesces beyond the interaction count limit")
    func keyRepeatCoalescesWithoutLoss() async throws {
        let harness = InputBufferingHarness()
        let session = harness.makeSession()
        let first = session.submitInput(.text("head", workspaceID: "workspace-1"))
        try await requireEventually { harness.pendingInputs.count == 1 }

        let receipts = (0..<100).map { _ in
            session.submitInput(.text("x", workspaceID: "workspace-1"))
        }
        #expect(harness.replayEpochs.isEmpty)
        #expect(session.queuedInteractionCount == 1)
        #expect(session.queuedInputByteCount == 100)
        guard harness.replayEpochs.isEmpty else {
            session.cancelForUnmount(nextEpoch: 2)
            for pending in harness.pendingInputs {
                pending.continuation.resume(returning: false)
            }
            return
        }

        harness.pendingInputs[0].continuation.resume(returning: true)
        let coalescedReady = try await pollUntil { harness.pendingInputs.count == 2 }
        #expect(coalescedReady)
        guard coalescedReady else { return }
        #expect(harness.pendingInputs[1].input == .text(String(repeating: "x", count: 100)))
        harness.pendingInputs[1].continuation.resume(returning: true)

        #expect(await first.value)
        for receipt in receipts {
            #expect(await receipt.value)
        }
        #expect(harness.recordedInputs == [
            .text("head"),
            .text(String(repeating: "x", count: 100)),
        ])
        #expect(harness.recordedEpochs == [2, 102])
    }

    @Test("production remount preserves the old session input result")
    func productionRemountPreservesDispatchedInput() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstPasteImage(true)
        let store = try await makeRoutingConnectedStore(router: router)
        let send = Task { @MainActor in
            await store.submitTerminalInputIntent(
                .image(
                    Data(repeating: 0x5A, count: 1_000_000),
                    format: "png",
                    workspaceID: RoutingHostRouter.workspaceID
                ),
                surfaceID: RoutingHostRouter.terminalA
            )
        }
        await router.awaitFirstPasteImageReached()
        let oldSession = try #require(
            store.terminalScrollSessionsBySurfaceID[RoutingHostRouter.terminalA]
        )

        _ = store.mountTerminalScrollSession(
            surfaceID: RoutingHostRouter.terminalA,
            cancelLocal: {}
        )
        #expect(store.terminalScrollSessionsBySurfaceID[RoutingHostRouter.terminalA] !== oldSession)
        await router.releaseFirstPasteImage()

        #expect(await send.value)
        #expect(await router.recordedPasteImages().count == 1)
        #expect(try await pollUntil { oldSession.inputTask == nil })
        guard case .idle = oldSession.phase else {
            Issue.record("Old remounted session did not clean up after its input result")
            return
        }
    }

    @Test("text coalescing stops at scroll click paste and image boundaries")
    func coalescingPreservesCausalBoundaries() async throws {
        let harness = InputBufferingHarness()
        let session = harness.makeSession()

        _ = session.submitInput(.text("head", workspaceID: "workspace-1"))
        try await requireEventually { harness.pendingInputs.count == 1 }
        _ = session.submitInput(.text("a", workspaceID: "workspace-1"))
        _ = session.submitInput(.text("b", workspaceID: "workspace-1"))
        session.submit(lines: -2, col: 1, row: 2)
        _ = session.submitInput(.text("c", workspaceID: "workspace-1"))
        _ = session.submitInput(.text("d", workspaceID: "workspace-1"))
        session.submitClick(col: 3, row: 4)
        _ = session.submitInput(.paste("paste", submitKey: "enter", workspaceID: "workspace-1"))
        _ = session.submitInput(.image(Data([1, 2, 3]), format: "png", workspaceID: "workspace-1"))

        harness.pendingInputs[0].continuation.resume(returning: true)
        guard try await resumeInput(.text("ab"), at: 1, harness: harness) else {
            session.cancelForUnmount(nextEpoch: 2)
            return
        }
        guard try await resumeInput(.text("cd"), at: 2, harness: harness) else {
            session.cancelForUnmount(nextEpoch: 2)
            return
        }
        guard try await resumeInput(.paste("paste", submitKey: "enter"), at: 3, harness: harness) else {
            session.cancelForUnmount(nextEpoch: 2)
            return
        }
        guard try await resumeInput(.image(byteCount: 3, format: "png"), at: 4, harness: harness) else {
            session.cancelForUnmount(nextEpoch: 2)
            return
        }

        #expect(try await pollUntil {
            if case .idle = session.phase { return true }
            return false
        })
        #expect(harness.events == [
            .input(.text("head")),
            .input(.text("ab")),
            .scroll([-2]),
            .input(.text("cd")),
            .click(col: 3, row: 4),
            .input(.paste("paste", submitKey: "enter")),
            .input(.image(byteCount: 3, format: "png")),
        ])
    }

    @Test("non-coalescible saturation rejects one input without draining the lane")
    func nonCoalescibleSaturationIsBounded() async throws {
        let harness = InputBufferingHarness()
        let session = harness.makeSession()
        let active = session.submitInput(.text("active", workspaceID: "workspace-1"))
        try await requireEventually { harness.pendingInputs.count == 1 }

        for index in 0..<TerminalScrollSession.maximumQueuedInteractionCount {
            if index.isMultiple(of: 2) {
                _ = session.submitInput(.paste("p", submitKey: "", workspaceID: "workspace-1"))
            } else {
                _ = session.submitInput(.image(Data([1]), format: "png", workspaceID: "workspace-1"))
            }
        }
        let rejected = session.submitInput(.paste("overflow", submitKey: "", workspaceID: "workspace-1"))

        #expect(await rejected.value == false)
        #expect(harness.replayEpochs.isEmpty)
        #expect(session.queuedInteractionCount == TerminalScrollSession.maximumQueuedInteractionCount)
        #expect(session.queuedInputByteCount <= TerminalScrollSession.maximumQueuedInputByteCount)

        session.cancelForUnmount(nextEpoch: 2)
        harness.pendingInputs[0].continuation.resume(returning: false)
        #expect(await active.value == false)
    }

    @Test("queued input byte overflow uses production failure guidance")
    func byteOverflowSurfacesProductionFailure() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstPasteImage(true)
        let store = try await makeRoutingConnectedStore(router: router)
        let send = Task { @MainActor in
            await store.submitTerminalInputIntent(
                .image(
                    Data(repeating: 0xA5, count: 1_000_000),
                    format: "png",
                    workspaceID: RoutingHostRouter.workspaceID
                ),
                surfaceID: RoutingHostRouter.terminalA
            )
        }
        await router.awaitFirstPasteImageReached()
        let session = try #require(store.terminalScrollSessionsBySurfaceID[RoutingHostRouter.terminalA])

        for _ in 0..<65 {
            _ = session.submitInput(.text(
                String(repeating: "x", count: 1_024),
                workspaceID: RoutingHostRouter.workspaceID
            ))
        }

        #expect(store.connectionError != nil)
        #expect(store.connectionState == .disconnected)
        #expect(session.queuedInputByteCount <= TerminalScrollSession.maximumQueuedInputByteCount)
        await router.releaseFirstPasteImage()
        #expect(await send.value == false)
        #expect(await router.recordedPasteImages().count == 1)
    }

    private func resumeInput(
        _ expected: RecordedInput,
        at index: Int,
        harness: InputBufferingHarness
    ) async throws -> Bool {
        let ready = try await pollUntil { harness.pendingInputs.count > index }
        #expect(ready)
        guard ready else { return false }
        let pending = harness.pendingInputs[index]
        #expect(pending.input == expected)
        guard pending.input == expected else {
            pending.continuation.resume(returning: false)
            return false
        }
        pending.continuation.resume(returning: true)
        return true
    }

    private func requireEventually(_ condition: @MainActor () async -> Bool) async throws {
        try #require(await pollUntil(condition))
    }
}

private extension TerminalInputIntent {
    var testName: String {
        switch self {
        case .text: "text"
        case .paste: "paste"
        case .image: "image"
        case .fence: "fence"
        }
    }
}

private enum LifecycleInputKind {
    static let allInputs: [TerminalInputIntent] = [
        .text("text", workspaceID: "workspace-1"),
        .paste("paste", submitKey: "enter", workspaceID: "workspace-1"),
        .image(Data([1, 2, 3]), format: "png", workspaceID: "workspace-1"),
    ]
}

private enum RecordedInput: Equatable {
    case text(String)
    case paste(String, submitKey: String)
    case image(byteCount: Int, format: String)

    init(_ input: TerminalInputIntent) {
        switch input {
        case .text(let text, _): self = .text(text)
        case .paste(let text, let submitKey, _): self = .paste(text, submitKey: submitKey)
        case .image(let data, let format, _): self = .image(byteCount: data.count, format: format)
        case .fence: self = .text("")
        }
    }
}

@MainActor
private final class InputBufferingHarness {
    enum Event: Equatable {
        case input(RecordedInput)
        case scroll([Double])
        case click(col: Int, row: Int)
    }

    struct PendingInput {
        let input: RecordedInput
        let continuation: CheckedContinuation<Bool, Never>
    }

    var pendingInputs: [PendingInput] = []
    var recordedInputs: [RecordedInput] = []
    var recordedEpochs: [UInt64] = []
    var events: [Event] = []
    var replayEpochs: [UInt64] = []
    var epoch: UInt64 = 1

    func makeSession() -> TerminalScrollSession {
        TerminalScrollSession(
            surfaceID: "surface-1",
            interactionEpoch: epoch,
            enqueueLocal: { _ in Self.resolvedReceipt() },
            enqueueBarrier: { Self.resolvedReceipt() },
            enqueueScrollToBottom: { Self.resolvedReceipt() },
            cancelLocal: {},
            sendRemote: { [weak self] request in
                self?.events.append(.scroll(request.directionalRuns.map(\.lines)))
                return TerminalScrollResponse(
                    accepted: true,
                    interactionEpoch: request.interactionEpoch,
                    clientRevision: request.clientRevision,
                    renderRevision: request.clientRevision,
                    renderGrid: nil
                )
            },
            sendClick: { [weak self] _, _, col, row in
                self?.events.append(.click(col: col, row: row))
                return true
            },
            sendInput: { [weak self] _, epoch, input in
                guard let self else { return false }
                let recorded = RecordedInput(input)
                recordedInputs.append(recorded)
                recordedEpochs.append(epoch)
                events.append(.input(recorded))
                return await withCheckedContinuation { continuation in
                    pendingInputs.append(PendingInput(input: recorded, continuation: continuation))
                }
            },
            interactionDeadline: { _ in },
            prepareIntent: {},
            deliverAuthoritative: { _, _, _, _ in true },
            completeGridlessAuthoritative: { _ in true },
            reconciliationDidComplete: {},
            requestReplay: { [weak self] epoch in self?.replayEpochs.append(epoch) },
            advanceEpoch: { [weak self] in
                guard let self else { return 0 }
                epoch += 1
                return epoch
            }
        )
    }

    private static func resolvedReceipt() -> TerminalSurfaceMutationReceipt {
        let receipt = TerminalSurfaceMutationReceipt()
        receipt.resolve(true)
        return receipt
    }
}
