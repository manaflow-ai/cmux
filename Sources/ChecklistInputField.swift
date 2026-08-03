import AppKit

/// A single-line AppKit text field for adding and editing checklist items
/// inside the checklist popover.
///
/// The `NSTextField` that grabs first responder on appear. The `selectsAllOnFocus`
/// flag chooses select-all (edit) vs caret-at-end (add) once the field editor exists.
/// Subclassable: the AppKit sidebar's checklist fields extend the window-attach
/// hook to clear the field editor's background after the deferred focus grab.
class FocusGrabbingTextField: NSTextField {
    var selectsAllOnFocus = false
    var caretColor: NSColor = .labelColor {
        didSet { (currentEditor() as? NSTextView)?.insertionPointColor = caretColor }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
#if DEBUG
        let windowKind = String(describing: type(of: window))
        let makeFirstResponderResult = window.makeFirstResponder(self)
        cmuxDebugLog(
            "focus.todoPopover.textField windowKind=\(windowKind) "
                + "isKeyWindow=\(window.isKeyWindow) "
                + "makeFirstResponder=\(makeFirstResponderResult)"
        )
#else
        window.makeFirstResponder(self)
#endif
        if selectsAllOnFocus {
            currentEditor()?.selectAll(nil)
        } else if let editor = currentEditor() {
            editor.selectedRange = NSRange(location: stringValue.count, length: 0)
        }
    }
}
