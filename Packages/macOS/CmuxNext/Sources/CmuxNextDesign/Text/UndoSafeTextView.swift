public import AppKit

/// An `NSTextView` whose programmatic text writes keep its undo stack valid.
///
/// AppKit's `string` setter swaps the text without telling the undo manager, so a typing action
/// recorded before it keeps a range into text that is gone, and the next Cmd-Z raises
/// `NSRangeException` in `-[NSTextStorage _undoRedoAttributedSubstringFromRange:]` (#24912). Here
/// every write to ``string`` is one undoable edit (`shouldChangeText` registers it, `didChangeText`
/// ends it), so undo steps back through the write instead of into a stale range.
///
/// Every cmux text view that sets `allowsUndo = true` derives from this class:
///
/// ```swift
/// package final class TextBoxTextView: UndoSafeTextView { ... }
/// ```
///
/// A write is a text change like typing: the delegate's `textDidChange(_:)` and
/// `didChangeText()` overrides run for it.
open class UndoSafeTextView: NSTextView {
    /// The text. Setting it replaces the whole text as one undo step (see ``replaceAllText(with:)``).
    open override var string: String {
        get { super.string }
        set { replaceAllText(with: newValue) }
    }

    /// Replaces the whole text with `text` as one undo step, apart from the typing before and after it.
    ///
    /// With undo off (or no undo manager yet, before the view is in a window) no undo action can
    /// point into the old text, so it is a plain set. When the view refuses the edit (not
    /// editable, or its delegate said no) the text is set anyway and the undo manager's actions
    /// are removed: their ranges point into the text that is gone.
    /// - Parameter text: The new text.
    public func replaceAllText(with text: String) {
        let current = super.string
        guard current != text else { return }
        guard allowsUndo, let undoManager, !undoManager.isUndoing, !undoManager.isRedoing else {
            super.string = text
            return
        }
        let all = NSRange(location: 0, length: (current as NSString).length)
        breakUndoCoalescing()
        if shouldChangeText(in: all, replacementString: text) {
            replaceCharacters(in: all, with: text)
            didChangeText()
        } else {
            super.string = text
            undoManager.removeAllActions()
        }
        breakUndoCoalescing()
    }
}
