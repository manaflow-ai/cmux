import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator worker failure conversion")
struct SimulatorWorkerFailureTests {
    @Test("Device-state failures remain recoverable")
    func recoverableDeviceFailure() {
        let failure = SimulatorWorkerFailure.deviceNotBooted("Shutdown").processSafeValue

        #expect(failure.code == "device_not_booted")
        #expect(failure.isRecoverable)
    }

    @Test("Framework failures require an Xcode state change")
    func frameworkFailure() {
        let failure = SimulatorWorkerFailure.frameworkUnavailable("missing").processSafeValue

        #expect(failure.code == "framework_unavailable")
        #expect(!failure.isRecoverable)
    }
}
