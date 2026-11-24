import AppKit

/// The list's search field cell: an unbezeled field (the Home list's, on its glass capsule) draws
/// and edits its text on one line centred in the field, beside the magnifier AppKit already
/// centres. AppKit puts an unbezeled field's text at its frame's top, 3 pt above the magnifier in a
/// 22 pt field (the user, 2026-10-29, "search is not centered"). A bezeled field keeps AppKit's own
/// placement.
///
/// The field editor goes in `searchTextRect(forBounds:)`, the rect the placeholder draws in at rest:
/// AppKit puts an unbezeled search field's editor in the frame it is handed, not right of the
/// magnifier, so the typed text and caret started over the magnifier
/// (https://github.com/manaflow-ai/cmux/issues/27967).
final class CmuxSidebarSearchFieldCell: NSSearchFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { centred(super.drawingRect(forBounds: rect)) }

    override func titleRect(forBounds rect: NSRect) -> NSRect { centred(super.titleRect(forBounds: rect)) }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect { centred(clearOfMagnifier(super.searchTextRect(forBounds: rect), in: rect)) }

    /// AppKit's text rect in a narrow unbezeled field starts under the magnifier, so the placeholder
    /// drew over it ("Searc" through the glass, the user 2026-11-23). It starts right of the magnifier
    /// (AppKit's own rect overlaps its slot by a point at every width): the field then measures the
    /// true room and shows the magnifier alone when "Search" does not fit (`CmuxSidebarSearchField`).
    private func clearOfMagnifier(_ text: NSRect, in rect: NSRect) -> NSRect {
        guard !isBezeled else { return text }
        let start = searchButtonRect(forBounds: rect).maxX - 1
        guard text.minX < start else { return text }
        var clear = text
        clear.size.width = max(0, text.maxX - start)
        clear.origin.x = start
        return clear
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: editorFrame(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: editorFrame(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    /// Where an unbezeled field's editor goes: the centred text rect, clear of the magnifier and the
    /// cancel button.
    private func editorFrame(_ rect: NSRect) -> NSRect { isBezeled ? rect : searchTextRect(forBounds: rect) }

    /// `rect` cut to one line of the field's font, centred on it (pixel-rounded by whole points).
    private func centred(_ rect: NSRect) -> NSRect {
        guard !isBezeled, let font else { return rect }
        let line = ceil(font.ascender - font.descender + font.leading)
        guard rect.height > line else { return rect }
        var centred = rect
        centred.origin.y += ((rect.height - line) / 2).rounded()
        centred.size.height = line
        return centred
    }
}
