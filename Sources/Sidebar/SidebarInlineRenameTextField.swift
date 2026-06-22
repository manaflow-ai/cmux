import AppKit

/// Text field that focuses and selects all text exactly when it enters a window.
final class SidebarInlineRenameTextField: NSTextField {
    /// Becomes first responder and selects the whole name as soon as the field
    /// enters a window, so typing immediately replaces the old name.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
}
