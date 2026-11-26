import AppKit
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator HID key mapping")
struct SimulatorHIDKeyMapperTests {
    @Test("Maps representative ANSI, navigation, and modifier keys")
    func representativeMappings() {
        #expect(simulatorHIDKeyMapper.usage(for: 0) == 0x04)
        #expect(simulatorHIDKeyMapper.usage(for: 36) == 0x28)
        #expect(simulatorHIDKeyMapper.usage(for: 123) == 0x50)
        #expect(simulatorHIDKeyMapper.usage(for: 55) == 0xE3)
        #expect(simulatorHIDKeyMapper.usage(for: 10) == nil)
    }

    @Test("Maps every AppKit numeric-keypad key to its USB usage")
    func numericKeypadMappings() {
        let expected: [UInt16: UInt32] = [
            65: 0x63,
            67: 0x55,
            69: 0x57,
            71: 0x53,
            75: 0x54,
            76: 0x58,
            78: 0x56,
            81: 0x67,
            82: 0x62,
            83: 0x59,
            84: 0x5A,
            85: 0x5B,
            86: 0x5C,
            87: 0x5D,
            88: 0x5E,
            89: 0x5F,
            91: 0x60,
            92: 0x61,
        ]

        for (keyCode, usage) in expected {
            #expect(simulatorHIDKeyMapper.usage(for: keyCode) == usage)
        }
        #expect(simulatorHIDKeyMapper.usage(for: 90) == nil)
    }

    @Test("Maps AppKit F13 through F15 to their USB compatibility usages")
    func extendedFunctionKeyMappings() {
        #expect(simulatorHIDKeyMapper.usage(for: 105) == 0x46)
        #expect(simulatorHIDKeyMapper.usage(for: 107) == 0x47)
        #expect(simulatorHIDKeyMapper.usage(for: 113) == 0x48)
    }

    @Test("Reads modifier transitions from AppKit flags")
    func modifierTransitions() {
        #expect(simulatorHIDKeyMapper.modifierIsDown(for: 56, flags: [.shift]) == true)
        #expect(simulatorHIDKeyMapper.modifierIsDown(for: 56, flags: []) == false)
        #expect(simulatorHIDKeyMapper.modifierIsDown(for: 0, flags: []) == nil)
    }
}
