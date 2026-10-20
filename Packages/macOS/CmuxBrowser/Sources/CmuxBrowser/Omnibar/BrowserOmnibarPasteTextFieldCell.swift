public import AppKit

/// Text-field cell that supplies an omnibar-aware field editor for every paste entrypoint.
public final class BrowserOmnibarPasteTextFieldCell: NSTextFieldCell {
    private lazy var pasteFieldEditor = BrowserOmnibarPasteFieldEditor()

    /// Creates an editable, selectable omnibar text-field cell.
    ///
    /// - Parameter string: The initial field value.
    public override init(textCell string: String) {
        super.init(textCell: string)
        isEditable = true
        isSelectable = true
    }

    /// Restores an omnibar text-field cell from an archive.
    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Supplies the field editor that sanitizes raw pasted URL text.
    ///
    /// - Parameter controlView: The text field beginning an editing session.
    /// - Returns: The cell's reusable omnibar paste field editor.
    public override func fieldEditor(for controlView: NSView) -> NSTextView? {
        pasteFieldEditor
    }
}
