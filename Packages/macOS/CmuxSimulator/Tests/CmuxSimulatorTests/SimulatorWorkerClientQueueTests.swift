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
}
