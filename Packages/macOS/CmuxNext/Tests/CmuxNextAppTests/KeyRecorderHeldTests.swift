import AppKit
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
}
