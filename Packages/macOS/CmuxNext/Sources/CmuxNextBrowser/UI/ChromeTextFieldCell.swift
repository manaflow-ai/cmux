import AppKit

/// The cell of every `ChromeTextField`. AppKit sets the field editor up again
/// each time the field starts editing (also when NSTextField's mouse-down
/// begins tracking a click, after `becomeFirstResponder`), and that resets the
/// editor's selection to the system blue. This cell puts the chrome colors
/// back on the editor after each set-up, so the selection stays the theme's
/// gray on every macOS.
class ChromeTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let textView = editor as? NSTextView, let field = controlView as? ChromeTextField {
            field.applyEditorColors(to: textView)
        }
        return editor
    }
}
