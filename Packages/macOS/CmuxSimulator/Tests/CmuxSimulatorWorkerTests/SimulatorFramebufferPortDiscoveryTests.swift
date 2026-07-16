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

    @Test("The built-in display wins over a larger external display")
    func primaryDisplayIdentityWins() async throws {
        let fixture = SimulatorFramebufferPortFixture(displays: [
            (screenID: 0, width: 8, height: 12),
            (screenID: 1, width: 30, height: 20),
        ])
        var metadata: SimulatorDisplayMetadata?
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { _ in },
            onDisplayChange: { metadata = $0 }
        )

        try await framebuffer.start(device: fixture.device)

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

    @Test("A failed publication resume remains retryable")
    func failedResumeCanRetry() async throws {
        let fixture = SimulatorFramebufferPortFixture()
        var transports: [SimulatorFrameTransportDescriptor] = []
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { transports.append($0) },
            onDisplayChange: { _ in }
        )
        try await framebuffer.start(device: fixture.device)
        try await framebuffer.setPublishingEnabled(false)
        fixture.removeSurface()

        await #expect(throws: SimulatorWorkerFailure.self) {
            try await framebuffer.setPublishingEnabled(true)
        }

        fixture.publishFrame(width: 8, height: 12)
        try await framebuffer.setPublishingEnabled(true)
        #expect(transports.count == 2)
    }
}
