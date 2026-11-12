import AppKit
import CmuxNextDesign
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

    /// The hint shows only in a terminal wide enough for the whole chip; a narrower one keeps it for a
    /// later drag instead of clipping it or spilling into the next pane.
    @Test func theHintWaitsForATerminalWideEnoughForIt() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 200))
        let hint = TerminalSelectionHint(view: view)
        hint.pressed([], captured: true)
        hint.dragged()
        #expect(hint.shownText == nil)
        hint.released()
        view.setFrameSize(NSSize(width: 800, height: 200))
        hint.pressed([], captured: true)
        hint.dragged()
        #expect(hint.shownText == TerminalSelectionHint.text)
        let chip = view.subviews.compactMap { $0 as? ShortcutHintChipView }.first
        #expect(chip.map { $0.frame.minX >= 0 && $0.frame.maxX <= view.bounds.width } == true)
        hint.hide()
    }

    /// A terminal that shrinks below the hint while it shows takes it down rather than clip it or
    /// let it spill into the next pane.
    @Test func aTerminalShrunkBelowTheHintHidesIt() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        let hint = TerminalSelectionHint(view: view)
        hint.pressed([], captured: true)
        hint.dragged()
        #expect(hint.shownText == TerminalSelectionHint.text)
        view.setFrameSize(NSSize(width: 700, height: 200))
        hint.resized()
        #expect(hint.shownText == TerminalSelectionHint.text)
        view.setFrameSize(NSSize(width: 60, height: 200))
        hint.resized()
        #expect(hint.shownText == nil)
    }

    /// A press whose release never comes (the terminal left its window mid-drag) leaves no Option
    /// selection or armed hint behind for a later press that skips the rule (a link click).
    @Test func aTerminalLeavingItsWindowEndsThePress() {
        let hint = TerminalSelectionHint(view: nil)
        hint.pressed(.option, captured: true)
        #expect(hint.selecting)
        hint.ended()
        #expect(!hint.selecting)
        #expect(hint.following(.option) == .option)
    }

    @Test(arguments: [NSEvent.ModifierFlags([]), .command, .shift, .option, .control, .function,
                      [.command, .shift, .option, .control, .function, .capsLock, .numericPad]])
    func keysRoundTrip(_ flags: NSEvent.ModifierFlags) {
        #expect(TerminalSelectionHint.flags(TerminalSelectionHint.keys(flags), keeping: flags) == flags)
    }
}
