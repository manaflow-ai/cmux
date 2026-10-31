public import AppKit

public extension NSTextView {
    /// Replaces the whole text from code as one undo step: Undo brings the previous text back.
    ///
    /// AppKit's `string` setter swaps the text without telling the undo manager, so a typing
    /// action recorded before it keeps a range into text that is gone, and the next Undo raises
    /// `NSRangeException` in `-[NSTextStorage _undoRedoAttributedSubstringFromRange:]` (#24912).
    /// This goes through the text system instead (`shouldChangeText`, `replaceCharacters`,
    /// `didChangeText`), with typing coalescing broken on both sides, so the replacement is its
    /// own undo step and the typing before it still undoes. The delegate's `textDidChange(_:)`
    /// runs, as for typing.
    ///
    /// With undo off, or before the view has an undo manager (not in a window yet), it is a
    /// plain set: no undo action can point into the old text. When the view refuses the edit
    /// (not editable, or its delegate said no) the text is set anyway and the undo manager's
    /// actions are removed, since their ranges point into the text that is gone.
    ///
    /// ```swift
    /// textView.replaceAllTextUndoably("")   // a submit clears the editor; Cmd-Z brings the draft back
    /// ```
    /// - Parameter text: The new text.
    func replaceAllTextUndoably(_ text: String) {
        let current = string
        guard current != text else { return }
        guard allowsUndo, let undoManager, !undoManager.isUndoing, !undoManager.isRedoing else {
            string = text
            return
        }
        let all = NSRange(location: 0, length: (current as NSString).length)
        breakUndoCoalescing()
        if shouldChangeText(in: all, replacementString: text) {
            replaceCharacters(in: all, with: text)
            didChangeText()
            breakUndoCoalescing()
        } else {
            string = text
            undoManager.removeAllActions()
        }
    }
}
