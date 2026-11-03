public import AppKit

/// A text field cell that draws its resting text and its placeholder where the field editor draws
/// typed text, so the line keeps its place when the field takes or loses the keyboard.
///
/// `NSTextFieldCell` in single-line mode draws its string, and the field editor draws its
/// placeholder, with string drawing, which puts the baseline from the font's ascender. The field
/// editor lays typed text out with TextKit (`NSLayoutManager`), whose baseline comes from the
/// typesetter's line height. With the bundled Inter the two differ by up to 4 pt at 18 pt: the
/// palette's "Search for commands…" sat 4 pt above the caret and the magnifier (Lawrence
/// 2026-10-29), and the omnibar's address moved 1 pt on every focus. This cell lays both out
/// with the editor's TextKit path, in the editor's text container geometry.
///
/// The line starts where the editor's does: while the field edits, at the editor's own text
/// container origin; at rest, at the origin of the title rect of the control's bounds, where AppKit
/// puts that editor in a borderless field, at the top of a field taller than its line. A fixed 3 pt shift left of the title rect put the palette's placeholder 3 pt
/// left of the caret, which then cut into its "S" (Lawrence 2026-11-02).
///
/// The placeholder is ``drawnPlaceholder``, which the cell keeps from the field editor (the
/// editor would draw its own copy at the string-drawing baseline). ``EditorAlignedTextField``
/// routes `placeholderString` and `placeholderAttributedString` to it, and redraws the cell as the
/// text changes, so use the two together:
///
/// ```swift
/// final class SearchField: EditorAlignedTextField {}
/// let field = SearchField()
/// field.placeholderString = "Search"
/// ```
open class EditorAlignedTextFieldCell: NSTextFieldCell {
    /// The placeholder this cell draws while the field is empty, editing or not. Nil draws none
    /// of its own (an AppKit placeholder set on the cell, if any, then draws as AppKit does).
    public var drawnPlaceholder: NSAttributedString? {
        didSet {
            setAccessibilityPlaceholderValue(drawnPlaceholder?.string)
            controlView?.needsDisplay = true
        }
    }

    private let restStorage = NSTextStorage()
    private let restLayout = NSLayoutManager()
    private let restContainer = NSTextContainer()

    public override init(textCell string: String) {
        super.init(textCell: string)
        configureRestLayout()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        configureRestLayout()
    }

    private func configureRestLayout() {
        restLayout.addTextContainer(restContainer)
        restStorage.addLayoutManager(restLayout)
        restContainer.maximumNumberOfLines = 1
        restContainer.lineBreakMode = .byTruncatingTail
    }

    open override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let editor = (controlView as? NSTextField)?.currentEditor() as? NSTextView
        if let editor {
            // The editor draws typed text; the cell draws the placeholder under an empty editor.
            super.drawInterior(withFrame: cellFrame, in: controlView)
            if editor.string.isEmpty, let drawnPlaceholder, drawnPlaceholder.length > 0 {
                drawLine(drawnPlaceholder, at: editor.convert(editor.textContainerOrigin, to: controlView), in: cellFrame,
                         padding: editor.textContainer?.lineFragmentPadding)
            }
            return
        }
        let value = attributedStringValue
        let text = value.length > 0 ? value : drawnPlaceholder
        guard let text, text.length > 0 else {
            return super.drawInterior(withFrame: cellFrame, in: controlView)
        }
        let editorPadding = (fieldEditor(for: controlView) ?? controlView.window?.fieldEditor(false, for: controlView) as? NSTextView)?
            .textContainer?.lineFragmentPadding
        // The control's own bounds, not `cellFrame`: in a field taller than its line AppKit passes a
        // vertically centered frame, but puts the editor at the top.
        drawLine(text, at: titleRect(forBounds: controlView.bounds).origin, in: cellFrame, padding: editorPadding)
    }

    /// Lays `text` out as the field editor would, its text container at `origin`, and draws it.
    private func drawLine(_ text: NSAttributedString, at origin: NSPoint, in cellFrame: NSRect, padding: CGFloat?) {
        // AppKit's field editor pads its line by 2 points a side.
        restContainer.lineFragmentPadding = padding ?? 2
        restContainer.size = NSSize(width: max(0, cellFrame.maxX - origin.x), height: .greatestFiniteMagnitude)
        restStorage.setAttributedString(text)
        let glyphs = restLayout.glyphRange(for: restContainer)
        restLayout.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}
