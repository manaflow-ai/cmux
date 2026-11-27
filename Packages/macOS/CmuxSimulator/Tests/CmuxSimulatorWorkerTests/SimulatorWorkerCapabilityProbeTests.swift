import CmuxSimulator
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator worker capability probe")
struct SimulatorWorkerCapabilityProbeTests {
    @Test("Host input capture is independently negotiated")
    func hostInputCapture() {
        var probe = SimulatorWorkerCapabilityProbe()
        #expect(!probe.capabilities.contains(.hostInputCapture))
        probe.hasHostInputCapture = true
        #expect(probe.capabilities.contains(.hostInputCapture))
    }
    @Test("Touch advertises single and multi-touch together")
    func touchCapabilitySet() {
        let capabilities = SimulatorWorkerCapabilityProbe(hasTouch: true).capabilities

        #expect(capabilities.contains(.touch))
        #expect(capabilities.contains(.multiTouch))
    }

    @Test("Either button transport advertises hardware buttons")
    func buttonFallbacks() {
        let legacy = SimulatorWorkerCapabilityProbe(hasLegacyButtons: true).capabilities
        let arbitrary = SimulatorWorkerCapabilityProbe(hasArbitraryButtons: true).capabilities

        #expect(legacy.contains(.hardwareButtons))
        #expect(arbitrary.contains(.hardwareButtons))
    }

    @Test("Unavailable private features are never advertised")
    func unavailableCapabilities() {
        let capabilities = SimulatorWorkerCapabilityProbe(
            hasFramebuffer: true,
            hasCameraInjection: false
        ).capabilities

        #expect(capabilities == [.framebuffer])
        #expect(!capabilities.contains(.cameraInjection))
        #expect(!capabilities.contains(.accessibility))
    }
}
