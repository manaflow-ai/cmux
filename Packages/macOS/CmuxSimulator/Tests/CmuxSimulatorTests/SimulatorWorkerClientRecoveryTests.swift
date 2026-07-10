import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("Explicit recovery replaces a worker whose Simulator became unavailable")
    func recoveryReattachesAfterDeviceUnavailable() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        try await client.sendRequired(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        first.emit(.status(.streaming))
        first.emit(.status(.deviceUnavailable))
        for _ in 0..<10_000 {
            if await client.currentStatus == .deviceUnavailable { break }
            await Task.yield()
        }

        try await client.recover()

        #expect(first.terminationCountValue() == 1)
        let replacement = try #require(launcher.endpoint(at: 1))
        #expect(replacement.inboundMessages().first == .attach(udid: "DEVICE", geometry: nil))
        await client.stop()
    }
}
