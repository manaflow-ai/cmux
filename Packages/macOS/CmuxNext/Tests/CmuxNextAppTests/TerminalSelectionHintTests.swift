import AppKit
import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
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

    /// The hint is a toast like every other (Lawrence 2026-11-12: "for option/shift space dialog when
    /// im trying to drag over terminals need a button for it to never show again"): it offers Don't
    /// Show Again, and once hidden it never shows on a drag again.
    @Test func theHintIsAToastThePersonCanHideForGood() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        window.contentView = view
        let store = CmuxToastNeverShowStore(defaults: UserDefaults(suiteName: "hint-\(UUID().uuidString)")!)
        let center = CmuxToastCenter(neverShow: store)
        let hint = TerminalSelectionHint(view: view, toasts: center)
        hint.pressed([], captured: true)
        hint.dragged()
        let shown = try #require(center.toasts(in: window).first)
        #expect(shown.id == TerminalSelectionHint.toastID)
        #expect(shown.message == TerminalSelectionHint.text)
        #expect(shown.offersNeverShow)
        #expect(hint.shownText == TerminalSelectionHint.text)
        hint.released()
        hint.hide()
        #expect(center.toasts(in: window).isEmpty)

        store.hide(TerminalSelectionHint.toastID)
        let later = TerminalSelectionHint(view: view, toasts: center)
        later.pressed([], captured: true)
        later.dragged()
        #expect(center.toasts(in: window).isEmpty)
        #expect(later.shownText == nil)
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
