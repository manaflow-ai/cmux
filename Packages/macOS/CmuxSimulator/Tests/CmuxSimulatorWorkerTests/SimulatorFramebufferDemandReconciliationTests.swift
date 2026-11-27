import CmuxSimulator
import Testing

@testable import CmuxSimulatorWorker

@Suite("Simulator framebuffer demand reconciliation")
struct SimulatorFramebufferDemandReconciliationTests {
    @Test("Repeated enable reannounces the current frame transport")
    @MainActor
    func repeatedEnableReannouncesCurrentTransport() async throws {
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(channel: fixture.worker)
        let transport = SimulatorFrameTransportDescriptor(
            sharedMemoryName: "/cmux-sim-frame-000000000001",
            width: 390,
            height: 844,
            bytesPerRow: 1_560,
            slotCount: 3,
            sharedMemoryByteCount: 3_949_632
        )
        coordinator.currentFrameTransport = transport

        #expect(await coordinator.handle(.setFramebufferPublishing(true)))
        #expect(await coordinator.handle(.ping(7)))

        #expect(try await fixture.receiveAsync() == .frameTransport(transport))
        #expect(try await fixture.receiveAsync() == .ack(7))
    }
}
