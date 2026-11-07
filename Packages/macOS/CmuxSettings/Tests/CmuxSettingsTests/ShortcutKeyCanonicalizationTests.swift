import Testing

@testable import CmuxSettings

@Suite("Shortcut key canonicalization")
struct ShortcutKeyCanonicalizationTests {
    @Test("records control-letter shortcuts from their physical key")
    func recordsControlLetterShortcut() {
        // Ctrl-F can be delivered as U+0006 in charactersIgnoringModifiers.
        // The recorder must still recover the physical F key so the built-in
        // fullscreen shortcut can be restored after a rebind.
        #expect(
            recordedShortcutKey(keyCode: 3, charactersIgnoringModifiers: "\u{0006}") == "f"
        )
    }
}
