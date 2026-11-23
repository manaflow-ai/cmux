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

    /// How far, in points, a line longer than the field fades out before the field's end. Zero (this cell's) ends it
    /// with an ellipsis instead; a subclass returns its width. Either way the line never draws past the end of the
    /// field's text box: since macOS 14 a view does not clip its drawing, so a long resting address ran under the
    /// trailing buttons to the window's edge (Lawrence 2026-11-20).
    open var overflowFadeWidth: CGFloat { 0 }

    /// A fading line's container width: wide enough for any one line (TextKit 1 lays out a horizontally
    /// resizable text view's line in the same 10 million points).
    private static let unboundedWidth: CGFloat = 10_000_000

    /// The fade's erase coverage, none to whole, drawn with `destinationOut`.
    private static let eraseRamp = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1]) // colour-allow: alpha-only erase coverage for the fade; this colour is never displayed

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
                drawLine(drawnPlaceholder, at: editor.convert(editor.textContainerOrigin, to: controlView),
                         in: textBox(cellFrame, of: controlView), padding: editor.textContainer?.lineFragmentPadding)
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
        drawLine(text, at: titleRect(forBounds: controlView.bounds).origin, in: textBox(cellFrame, of: controlView), padding: editorPadding)
    }

    /// Where a line may draw: across the title rect of the control's bounds (where AppKit puts the field editor's
    /// clip), inside `cellFrame`; a whole line height above and below the bounds, so no glyph loses its top or bottom.
    private func textBox(_ cellFrame: NSRect, of controlView: NSView) -> NSRect {
        let bounds = controlView.bounds
        let title = titleRect(forBounds: bounds)
        let minX = max(title.minX, cellFrame.minX)
        let maxX = max(minX, min(title.maxX, cellFrame.maxX))
        return NSRect(x: minX, y: bounds.minY - bounds.height, width: maxX - minX, height: 3 * bounds.height)
    }

    /// Lays `text` out as the field editor would, its text container at `origin`, and draws it inside `box` (in the
    /// control's coordinates) and nowhere else: past the box's end it is cut off with an ellipsis, or it fades out over
    /// ``overflowFadeWidth``.
    private func drawLine(_ text: NSAttributedString, at origin: NSPoint, in box: NSRect, padding: CGFloat?) {
        let fade = min(overflowFadeWidth, box.width)
        // AppKit's field editor pads its line by 2 points a side.
        restContainer.lineFragmentPadding = padding ?? 2
        // A fading line is laid out whole and cut by the clip below; else the container ends at the box and truncates.
        restContainer.lineBreakMode = fade > 0 ? .byClipping : .byTruncatingTail
        let width = fade > 0 ? Self.unboundedWidth : max(0, box.maxX - origin.x)
        restContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        restStorage.setAttributedString(text)
        let glyphs = restLayout.glyphRange(for: restContainer)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: box)
        let inkEnd = origin.x + restLayout.usedRect(for: restContainer).maxX - restContainer.lineFragmentPadding
        guard fade > 0, inkEnd > box.maxX, let ramp = Self.eraseRamp else {
            restLayout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            return
        }
        // The glyphs in their own layer, then the box's last `fade` points erased from clear to whole.
        context.beginTransparencyLayer(in: box, auxiliaryInfo: nil)
        restLayout.drawGlyphs(forGlyphRange: glyphs, at: origin)
        context.setBlendMode(.destinationOut)
        context.drawLinearGradient(ramp, start: CGPoint(x: box.maxX - fade, y: box.minY), end: CGPoint(x: box.maxX, y: box.minY),
                                   options: [.drawsAfterEndLocation])
        context.endTransparencyLayer()
    }
}
