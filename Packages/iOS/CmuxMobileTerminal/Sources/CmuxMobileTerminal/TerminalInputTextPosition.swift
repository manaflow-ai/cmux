import UIKit

/// An offset-bearing text position for the terminal input view's hand-rolled
/// ``UITextInput`` conformance.
///
/// ``TerminalInputTextView`` is a documentless remote-terminal proxy: it owns no
/// editable buffer of real characters. But to make the software keyboard's
/// *hold-to-repeat* backspace fire on the modern document-driven repeat path
/// (not just the legacy ``UIKeyInput/hasText`` poll), the view presents a
/// one-character zero-width *virtual* document with the caret at the end
/// whenever there is no IME composition. UIKit walks that document through
/// ``UITextPosition``/``UITextRange`` offsets — `beginningOfDocument` at offset
/// 0, `endOfDocument` at offset 1 — so the framework always believes there is a
/// deletable character to the left of the cursor and keeps re-firing
/// ``UIKeyInput/deleteBackward()`` while backspace is held.
///
/// This mirrors vvterm's `TerminalNativeTextPosition`, which is what lets vvterm
/// drive UIKit's document-based delete-repeat from an offscreen `UITextInput`
/// proxy. The offset is therefore meaningful (0 or the anchor length), unlike a
/// pure identity sentinel.
final class TerminalInputTextPosition: UITextPosition {
    /// The UTF-16 offset this position addresses within the virtual document.
    let offset: Int

    init(offset: Int) {
        self.offset = offset
    }
}
