import AppKit

extension TerminalPanel {
    /// Shows or hides the TextBox Input for a socket or CLI request
    /// (`cmux textbox`, `surface.textbox.*`).
    ///
    /// Unlike the command palette toggle, this never takes keyboard focus on its
    /// own: a shown TextBox gets focus only when `focus` is true, and hiding a
    /// TextBox that owns the first responder hands focus to this panel's own
    /// terminal, so focus never leaves the pane it was in.
    ///
    /// - Parameters:
    ///   - visible: Whether the TextBox should be shown.
    ///   - focus: Whether a shown TextBox should take keyboard focus.
    /// - Returns: Whether the TextBox visibility changed.
    @discardableResult
    func setTextBoxInputVisible(_ visible: Bool, focus: Bool) -> Bool {
        let wasVisible = isTextBoxActive
        if visible {
            if focus {
                focusTextBoxInput()
            } else if !wasVisible {
                showTextBoxInputWhenAvailable()
            }
            return !wasVisible
        }
        guard wasVisible else { return false }
        hideTextBoxInput(focusTerminal: textBoxOwnsResponder(textBoxInputView?.window?.firstResponder))
        return true
    }
}
