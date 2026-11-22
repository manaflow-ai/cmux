public import AppKit

/// A text field whose resting text and placeholder sit on the line the field editor types on.
///
/// Its cell is an ``EditorAlignedTextFieldCell`` (a subclass may name a subclass of it). The
/// placeholder setters store the placeholder on that cell instead of AppKit's, so the field editor
/// never draws its own copy at a different baseline, and every text change redraws the cell, which
/// shows or hides the placeholder under the editor.
///
/// ```swift
/// final class PaletteSearchField: EditorAlignedTextField {}
/// ```
open class EditorAlignedTextField: NSTextField {
    open override class var cellClass: AnyClass? {
        get { EditorAlignedTextFieldCell.self }
        set {}
    }

    private var alignedCell: EditorAlignedTextFieldCell? { cell as? EditorAlignedTextFieldCell }

    /// The placeholder, kept on the cell (``EditorAlignedTextFieldCell/drawnPlaceholder``).
    open override var placeholderAttributedString: NSAttributedString? {
        get { alignedCell?.drawnPlaceholder ?? super.placeholderAttributedString }
        set {
            guard let alignedCell else { return super.placeholderAttributedString = newValue }
            alignedCell.drawnPlaceholder = newValue
        }
    }

    /// The placeholder as plain text, drawn in the field's font and the placeholder text color.
    open override var placeholderString: String? {
        get { alignedCell?.drawnPlaceholder?.string ?? super.placeholderString }
        set {
            guard let alignedCell else { return super.placeholderString = newValue }
            alignedCell.drawnPlaceholder = newValue.map {
                NSAttributedString(string: $0, attributes: [
                    .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.placeholderTextColor,
                ])
            }
        }
    }

    open override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        // The cell draws the placeholder under the editor: show or hide it with the text.
        needsDisplay = true
    }
}
