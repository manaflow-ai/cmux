import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator device state gate")
struct SimulatorDeviceStateGateTests {
    @Test("A non-booted transition is emitted once until booted again")
    func stateTransitions() {
        var gate = SimulatorDeviceStateGate()

        #expect(gate.observe(state: "Booted") == nil)
        #expect(gate.observe(state: "Shutting Down") == .becameUnavailable(
            state: "Shutting Down"
        ))
        #expect(gate.observe(state: "Shutdown") == nil)
        #expect(gate.observe(state: "Booted") == nil)
        #expect(gate.observe(state: "Shutdown") == .becameUnavailable(state: "Shutdown"))
    }
}
