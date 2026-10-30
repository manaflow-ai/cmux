import AppKit

/// The list's search field cell: an unbezeled field (the Home list's, on its glass capsule) draws
/// and edits its text on one line centred in the field, beside the magnifier AppKit already
/// centres. AppKit puts an unbezeled field's text at its frame's top, 3 pt above the magnifier in a
/// 22 pt field (the user, 2026-10-29, "search is not centered"). A bezeled field keeps AppKit's own
/// placement.
///
/// Editing takes the whole cell frame, as drawing does: AppKit places the field editor in
/// `searchTextRect(forBounds:)` of that frame, which is centred here. A frame already cut to one
/// line gave AppKit a short cell whose magnifier slot is narrower, so the typed text and caret
/// started over the magnifier (https://github.com/manaflow-ai/cmux/issues/27967).
final class CmuxSidebarSearchFieldCell: NSSearchFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { centred(super.drawingRect(forBounds: rect)) }

    override func titleRect(forBounds rect: NSRect) -> NSRect { centred(super.titleRect(forBounds: rect)) }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect { centred(super.searchTextRect(forBounds: rect)) }

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
