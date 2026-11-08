import CmuxSimulator
import Testing
@testable import CmuxSimulatorWorker

@Suite("Worker held HID buttons")
struct SimulatorHeldHIDButtonStateTests {
    @Test("Cleanup releases every simultaneous raw HID hold in stable order")
    func releaseHeldButtons() {
        let volume = SimulatorHIDButtonUsage(page: 0x0C, usage: 0xE9)
        let action = SimulatorHIDButtonUsage(page: 0x0B, usage: 0x2D)
        var state = SimulatorHeldHIDButtonState()
        state.record(SimulatorHIDButtonEvent(button: volume, phase: .down))
        state.record(SimulatorHIDButtonEvent(button: action, phase: .down))

        #expect(state.takeReleaseEvents() == [
            SimulatorHIDButtonEvent(button: action, phase: .up),
            SimulatorHIDButtonEvent(button: volume, phase: .up),
        ])
        #expect(state.buttons.isEmpty)
    }

    @Test("An explicit up removes only its matching hold")
    func explicitRelease() {
        let first = SimulatorHIDButtonUsage(page: 1, usage: 2)
        let second = SimulatorHIDButtonUsage(page: 1, usage: 3)
        var state = SimulatorHeldHIDButtonState()
        state.record(SimulatorHIDButtonEvent(button: first, phase: .down))
        state.record(SimulatorHIDButtonEvent(button: second, phase: .down))
        state.record(SimulatorHIDButtonEvent(button: first, phase: .up))

        #expect(state.buttons == [second])
    }
}
