import CmuxSimulator
import Foundation
import IOSurface
import Testing

@testable import CmuxSimulatorWorker

@Suite("Simulator framebuffer port discovery")
@MainActor
struct SimulatorFramebufferPortDiscoveryTests {
    @Test("Framebuffer discovery uses the current ioPorts contract")
    func currentIOPortsContract() async throws {
        let fixture = SimulatorFramebufferPortFixture()
        var transport: SimulatorFrameTransportDescriptor?
        var metadata: SimulatorDisplayMetadata?
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { transport = $0 },
            onDisplayChange: { metadata = $0 }
        )

        try await framebuffer.start(device: fixture.device)

        #expect(fixture.didRequestCurrentPorts)
        #expect(transport?.width == 8)
        #expect(transport?.height == 12)
        #expect(metadata?.width == 8)
        #expect(metadata?.height == 12)
    }

    @Test("Stopping rejects a dimension change already waiting to publish")
    func stoppedFramebufferRejectsLateTransport() async throws {
        let fixture = SimulatorFramebufferPortFixture()
        let gate = SimulatorFrameTransportPublicationGate()
        var transports: [SimulatorFrameTransportDescriptor] = []
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { transports.append($0) },
            onDisplayChange: { _ in },
            beforeFrameTransportChange: { await gate.wait() },
            afterFrameTransportChange: { await gate.completeAttempt() }
        )
        try await framebuffer.start(device: fixture.device)

        fixture.publishFrame(width: 12, height: 18)
        try await gate.waitUntilBlocked()
        framebuffer.stop()
        await gate.release()
        try await gate.waitUntilAttemptCompleted()

        #expect(transports.count == 1)
        #expect(transports.first?.width == 8)
        #expect(transports.first?.height == 12)
    }
}
