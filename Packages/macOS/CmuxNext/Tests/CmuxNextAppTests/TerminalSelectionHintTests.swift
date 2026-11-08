import AppKit
@testable import CmuxNextTerminal
import GhosttyNextKit
import Testing

/// The terminal's Option-drag selection through cmux-motion's rule over the app FFI: the event's keys
/// go in and out as the rule's bits, and the other bits of the flags stay.
@MainActor
@Suite struct TerminalSelectionHintTests {
    @Test func optionDragInACaptureGoesAsTheShiftOverride() {
        let hint = TerminalSelectionHint(view: nil)
        #expect(hint.pressAsksCapture(.option))
        hint.pressed(.option, captured: true)
        #expect(hint.selecting)
        #expect(hint.following(.option) == .shift)
        #expect(hint.following([.option, .capsLock]) == [.shift, .capsLock])
        #expect(hint.following([]) == .shift)
        hint.released()
        #expect(!hint.selecting)
    }

    @Test func optionWithoutACaptureAndOtherKeysStayAsTheyAre() {
        let hint = TerminalSelectionHint(view: nil)
        hint.pressed(.option, captured: false)
        #expect(!hint.selecting)
        for flags: NSEvent.ModifierFlags in [.shift, [.option, .shift], [.option, .command], .command] {
            hint.pressed(flags, captured: true)
            #expect(!hint.selecting)
        }
    }

    /// A right Option replaced by Shift reaches Ghostty as plain Shift, not Shift with Alt-Right.
    @Test func rightOptionLosesItsSideBit() {
        let hint = TerminalSelectionHint(view: nil)
        let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK))
        hint.pressed(rightOption, captured: true)
        let sent = hint.following(rightOption)
        #expect(sent.rawValue & UInt(NX_DEVICERALTKEYMASK) == 0)
        #expect(GhosttyInput.mods(sent).rawValue == GhosttyInput.mods(.shift).rawValue)
    }

    @Test(arguments: [NSEvent.ModifierFlags([]), .command, .shift, .option, .control, .function,
                      [.command, .shift, .option, .control, .function, .capsLock, .numericPad]])
    func keysRoundTrip(_ flags: NSEvent.ModifierFlags) {
        #expect(TerminalSelectionHint.flags(TerminalSelectionHint.keys(flags), keeping: flags) == flags)
    }
}
