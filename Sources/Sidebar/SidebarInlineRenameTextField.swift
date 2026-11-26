import AppKit

/// Text field that focuses and selects all text exactly when it enters a window.
final class SidebarInlineRenameTextField: NSTextField {
    /// The row-resolved foreground color for typed text and the field-editor caret.
    var inlineRenameTextColor: NSColor = .labelColor {
        didSet { applyInlineRenameTextColor() }
    }

    /// Becomes first responder and selects the whole name as soon as the field
    /// enters a window, so typing immediately replaces the old name.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        applyInlineRenameTextColor()
        currentEditor()?.selectAll(nil)
    }

    private func applyInlineRenameTextColor() {
        textColor = inlineRenameTextColor
        (currentEditor() as? NSTextView)?.insertionPointColor = inlineRenameTextColor
    }
}
