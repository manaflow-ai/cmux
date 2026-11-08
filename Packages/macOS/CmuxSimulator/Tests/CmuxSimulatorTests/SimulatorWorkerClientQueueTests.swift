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
}
