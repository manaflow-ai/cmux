import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("A full deferred input queue rejects traffic without restarting a healthy worker")
    func deferredInputCapacityDoesNotSpendCrashRecovery() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        try await client.sendRequired(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))

        for usage in UInt32(4)..<12 {
            try await client.sendRequired(.key(SimulatorKeyEvent(usage: usage, phase: .down)))
        }

        await #expect(throws: SimulatorControlError.self) {
            try await client.sendRequired(.key(SimulatorKeyEvent(usage: 12, phase: .down)))
        }
        #expect(endpoint.terminationCountValue() == 0)
        #expect(launcher.endpoint(at: 1) == nil)
        #expect(await client.deferredMessages.count == 8)

        await client.stop()
    }

    @Test("Cancelling a deferred request removes it before worker delivery")
    func cancelledDeferredRequestIsNeverDelivered() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        try await client.sendRequired(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        let requestID = UUID()
        let request = SimulatorWorkerInbound.reloadReactNative(requestID: requestID)

        let operation = Task<Bool, Error> {
            try await client.requestWorkerValue(
                sending: request,
                timeout: .seconds(60),
                timeoutRecovery: .preserveWorker
            ) { message in
                guard case let .reactNativeReload(responseID, succeeded) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
        }
        for _ in 0..<10_000 {
            if await client.deferredMessages.contains(request) { break }
            await Task.yield()
        }
        #expect(await client.deferredMessages.contains(request))

        operation.cancel()
        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        for _ in 0..<10_000 {
            if !(await client.deferredMessages.contains(request)) { break }
            await Task.yield()
        }
        #expect(!(await client.deferredMessages.contains(request)))

        endpoint.emit(.status(.streaming))
        for _ in 0..<100 { await Task.yield() }
        #expect(!endpoint.inboundMessages().contains(request))
        await client.stop()
    }

    @Test("A command that launches recovery waits behind the replacement attachment")
    func commandThatLaunchesRecoveryWaitsForStreaming() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        try await client.sendRequired(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        first.emit(.status(.streaming))
        for _ in 0..<100 { await Task.yield() }
        await client.discardWorker(intentional: true, clearReplayState: false)

        let key = SimulatorWorkerInbound.key(SimulatorKeyEvent(usage: 4, phase: .down))
        try await client.sendRequired(key)
        let replacement = try #require(launcher.endpoint(at: 1))

        #expect(replacement.inboundMessages() == [.attach(udid: "DEVICE", geometry: nil)])
        #expect(!replacement.inboundMessages().contains(key))
        await client.stop()
    }

    @Test("A failed liveness probe never retries a command whose frame was delivered")
    func probeFailureDoesNotDuplicateDeliveredCommand() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        try await client.recover()
        let first = try #require(launcher.endpoint(at: 0))
        first.failNextSend { message in
            if case .ping = message { return true }
            return false
        }
        let request = SimulatorWorkerInbound.reloadReactNative(requestID: UUID())

        await #expect(throws: SimulatorControlError.self) {
            try await client.sendRequired(request)
        }
        let replacement = try #require(launcher.endpoint(at: 1))
        #expect(first.inboundMessages().contains(request))
        #expect(!replacement.inboundMessages().contains(request))
        await client.stop()
    }

    @Test("Input quiescence waits behind deferred live input and releases last")
    func inputQuiescenceFencesDeferredLiveInput() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        try await client.recover()
        let endpoint = try #require(launcher.endpoint(at: 0))
        let resize = SimulatorWorkerInbound.resize(SimulatorSurfaceGeometry(
            width: 800,
            height: 600,
            scale: 2
        ))
        try await client.sendRequired(resize)
        let messagesWithBlockingPing = try #require(await endpoint.waitForInboundMessages {
            $0.contains { if case .ping = $0 { true } else { false } }
        })
        let pingSequences: [UInt64] = messagesWithBlockingPing.compactMap {
            guard case let .ping(sequence) = $0 else { return nil }
            return sequence
        }
        let blockingSequence = try #require(pingSequences.last)
        let scroll = SimulatorWorkerInbound.scrollWheel(SimulatorScrollWheelEvent(
            id: UUID(),
            anchor: SimulatorPoint(x: 0.5, y: 0.5),
            deltaX: 0,
            deltaY: 0.25
        ))
        try await client.sendRequired(scroll)
        let operation = Task { try await client.quiesceInputDelivery() }
        for _ in 0..<10_000 {
            if await client.deferredMessages.contains(where: {
                if case .quiesceInput = $0 { true } else { false }
            }) { break }
            await Task.yield()
        }

        #expect(!endpoint.inboundMessages().contains(scroll))
        #expect(!endpoint.inboundMessages().contains {
            if case .quiesceInput = $0 { true } else { false }
        })
        endpoint.setResponder { message in
            switch message {
            case let .ping(sequence):
                .ack(sequence)
            case let .quiesceInput(requestID):
                .inputQuiesced(requestID: requestID)
            default:
                nil
            }
        }
        endpoint.emit(.ack(blockingSequence))
        try await operation.value

        let delivered = endpoint.inboundMessages()
        let scrollIndex = try #require(delivered.firstIndex(of: scroll))
        let fenceIndex = try #require(delivered.firstIndex {
            if case .quiesceInput = $0 { true } else { false }
        })
        #expect(scrollIndex < fenceIndex)
        await client.stop()
    }
}
