import AppKit
import Testing
import CmuxTerminalCore
import CmuxTerminalCopyMode

@Suite struct CopyModeModifierMappingTests {
    @Test func mapsEachRelevantFlag() {
        #expect(TerminalKeyboardCopyModeModifiers(modifierFlags: .command) == [.command])
        #expect(TerminalKeyboardCopyModeModifiers(modifierFlags: .shift) == [.shift])
        #expect(TerminalKeyboardCopyModeModifiers(modifierFlags: .control) == [.control])
        #expect(TerminalKeyboardCopyModeModifiers(modifierFlags: .numericPad) == [.numericPad])
        #expect(TerminalKeyboardCopyModeModifiers(modifierFlags: .function) == [.function])
        #expect(TerminalKeyboardCopyModeModifiers(modifierFlags: .capsLock) == [.capsLock])
    }

    @Test func combinesMultipleFlags() {
        #expect(
            TerminalKeyboardCopyModeModifiers(modifierFlags: [.command, .shift])
                == [.command, .shift]
        )
    }

    @Test func ignoresOptionAndDeviceDependentBits() {
        #expect(TerminalKeyboardCopyModeModifiers(modifierFlags: .option) == [])
        let withDeviceBits = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2 // raw left-shift device bit
        )
        #expect(TerminalKeyboardCopyModeModifiers(modifierFlags: withDeviceBits) == [.shift])
    }
}
