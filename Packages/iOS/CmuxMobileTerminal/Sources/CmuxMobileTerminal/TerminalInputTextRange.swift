import UIKit

/// An offset-bearing text range for the terminal input view's hand-rolled
/// ``UITextInput`` conformance.
///
/// Like ``TerminalInputTextPosition``, this carries real UTF-16 offsets rather
/// than acting as a pure identity sentinel. ``TerminalInputTextView`` exposes a
/// short virtual document — either the in-progress IME ``markedText`` or, when
/// no IME is composing, a one-character zero-width *delete-repeat anchor* — and
/// UIKit addresses that document through these ranges. Measurable offsets are
/// what let the view report a one-character document with the caret at the end
/// (`endOfDocument` at offset 1), which is the condition the software keyboard's
/// modern document-driven backspace auto-repeat checks before each repeat.
///
/// This mirrors vvterm's `TerminalNativeTextRange`. The previous documentless
/// attempt used an identity-only range whose length was always zero, so UIKit
/// saw "nothing to delete" and the repeat died after one delete; the offsets
/// here fix exactly that.
final class TerminalInputTextRange: UITextRange {
    private let startOffset: Int
    private let endOffset: Int

    init(start: Int, end: Int) {
        self.startOffset = start
        self.endOffset = end
    }

    /// The UTF-16 range this addresses within the virtual document. UIKit hands
    /// this back via `markedTextRange` / `selectedTextRange`; the view answers
    /// `text(in:)` by slicing its current virtual document with this range.
    var nsRange: NSRange {
        NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    }

    override var start: UITextPosition { TerminalInputTextPosition(offset: startOffset) }
    override var end: UITextPosition { TerminalInputTextPosition(offset: endOffset) }
    override var isEmpty: Bool { endOffset <= startOffset }
}
