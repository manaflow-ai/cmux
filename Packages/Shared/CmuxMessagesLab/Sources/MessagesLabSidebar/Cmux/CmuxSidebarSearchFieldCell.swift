import AppKit

/// The list's search field cell: an unbezeled field (the Home list's, on its glass capsule) draws
/// and edits its text on one line centred in the field, beside the magnifier AppKit already
/// centres. AppKit puts an unbezeled field's text at its frame's top, 3 pt above the magnifier in a
/// 22 pt field (the user, 2026-10-29, "search is not centered"). A bezeled field keeps AppKit's own
/// placement.
final class CmuxSidebarSearchFieldCell: NSSearchFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { centred(super.drawingRect(forBounds: rect)) }

    override func titleRect(forBounds rect: NSRect) -> NSRect { centred(super.titleRect(forBounds: rect)) }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect { centred(super.searchTextRect(forBounds: rect)) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centred(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centred(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

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
