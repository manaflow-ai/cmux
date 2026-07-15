import CmuxSimulator
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator worker keyboard activity")
struct SimulatorWorkerKeyboardActivityTests {
    @Test("Ordinary key events do not publish activity rows")
    @MainActor
    func ordinaryKeysStayOffActivityStream() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(channel: fixture.worker)
        coordinator.hid = SimulatorHIDTransport(
            frameworkLoader: coordinator.frameworkLoader,
            keySenderOverride: { _ in true }
        )

        #expect(await coordinator.handle(.key(.init(usage: 4, phase: .down))))
        #expect(await coordinator.handle(.key(.init(usage: 4, phase: .up))))
        #expect(await coordinator.handle(.ping(42)))

        #expect(try await fixture.receiveAsync() == .ack(42))
    }
}
