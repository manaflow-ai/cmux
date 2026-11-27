import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The Keyboard Shortcuts recorder shows the modifiers held before a key makes the stroke
/// (`held` on the `recorded` stream), in the order a stroke's display writes them (⇧⌘P).
@Suite struct KeyRecorderHeldTests {
    @Test func heldModifiersReadInMenuOrder() {
        #expect(KeyRecorder.heldGlyphs([]) == "")
        #expect(KeyRecorder.heldGlyphs([.command]) == "⌘")
        #expect(KeyRecorder.heldGlyphs([.command, .shift]) == "⇧⌘")
        #expect(KeyRecorder.heldGlyphs([.command, .option, .control, .shift, .capsLock]) == "⌃⌥⇧⌘")
    }

    /// Keypad Enter (U+0003) on a fresh recorder is the same Return stroke as Return, so the page
    /// closes on it (Codex QA on the keyclick build, 2026-10-24: it showed U+0003 and "needs ⌘").
    @Test func keypadEnterFirstIsAReturnStroke() {
        var recorder = KeyRecorder()
        let event = recorder.record(Shortcut("\u{3}", modifiers: []), isEscape: false, isReturn: true)
        #expect(event?.keys == [Shortcut(Shortcut.returnKey, modifiers: [])])
        #expect(event?.done == false)
    }
}
