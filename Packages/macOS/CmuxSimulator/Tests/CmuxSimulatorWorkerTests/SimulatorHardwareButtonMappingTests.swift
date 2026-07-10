import CmuxSimulator
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator hardware button mapping")
struct SimulatorHardwareButtonMappingTests {
    @Test("DeviceKit buttons use the expected HID pages and usages", arguments: [
        (SimulatorHardwareButton.power, SimulatorHardwareButtonMapping.arbitrary(page: 0x0C, usage: 0x30)),
        (SimulatorHardwareButton.volumeUp, SimulatorHardwareButtonMapping.arbitrary(page: 0x0C, usage: 0xE9)),
        (SimulatorHardwareButton.volumeDown, SimulatorHardwareButtonMapping.arbitrary(page: 0x0C, usage: 0xEA)),
        (SimulatorHardwareButton.action, SimulatorHardwareButtonMapping.arbitrary(page: 0x0B, usage: 0x2D)),
        (SimulatorHardwareButton.watchSideButton, SimulatorHardwareButtonMapping.arbitrary(page: 0x0C, usage: 0x95)),
    ])
    func arbitraryButtonMapping(
        button: SimulatorHardwareButton,
        expected: SimulatorHardwareButtonMapping
    ) {
        #expect(SimulatorHardwareButtonMapping(button) == expected)
    }

    @Test("System gesture buttons stay on the touch transport")
    func systemGestureMapping() {
        #expect(SimulatorHardwareButtonMapping(.swipeHome) == .swipeHome)
        #expect(SimulatorHardwareButtonMapping(.appSwitcher) == .appSwitcher)
    }
}
