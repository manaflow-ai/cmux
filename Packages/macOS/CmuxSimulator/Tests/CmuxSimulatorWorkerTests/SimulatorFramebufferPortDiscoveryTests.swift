import CmuxSimulator
import Foundation
import IOSurface
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator framebuffer port discovery")
@MainActor
struct SimulatorFramebufferPortDiscoveryTests {
    @Test("Framebuffer discovery uses the current ioPorts contract")
    func currentIOPortsContract() throws {
        let fixture = SimulatorFramebufferPortFixture()
        let context = try SimulatorRemoteRenderContext()
        var metadata: SimulatorDisplayMetadata?
        let framebuffer = SimulatorFramebuffer(renderContext: context) { value in
            metadata = value
        }

        try framebuffer.start(device: fixture.device)

        #expect(fixture.didRequestCurrentPorts)
        #expect(metadata?.width == 8)
        #expect(metadata?.height == 12)
    }
}
