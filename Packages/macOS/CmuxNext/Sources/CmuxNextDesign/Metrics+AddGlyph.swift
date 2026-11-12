public import AppKit

// The one size class of the window's add buttons: the tab row's New Tab + and its pane-type
// chevron, and the sidebar's New Workspace + (Leo 2026-11-07: "decrease the size of the tab area
// plus button, or increase the size of the new workspace area button? Or I guess, like, probably
// do something in the middle"). The tab row drew a 10 pt + at 1.4 pt and the sidebar its pack icon,
// an 8 pt + at 0.9 pt; both now draw the one + between them, and the chevron beside a + matches it.
extension Metrics {
    /// How far the + reaches end to end: 9 pt at Compact, between the two it replaces.
    public static var addGlyphExtent: CGFloat { (smallIconSize * 0.75 * 2).rounded() / 2 }
    /// The +'s stroke at rest (a held press draws it heavier, `addGlyphPressedLineWidth`).
    public static var addGlyphLineWidth: CGFloat { space1 * 0.6 }
    /// The +'s stroke while held or while its menu is open.
    public static var addGlyphPressedLineWidth: CGFloat { space1 * 0.9 }
    /// The tab row's pane-type chevron beside its +: an SF chevron at this point size spans about
    /// the +'s width. (The sidebar's chooser keeps its smaller menu-indicator chevron.)
    public static var addMenuChevronPointSize: CGFloat { (addGlyphExtent + space1 / 2).rounded() }
}

extension CGPath {
    /// The add buttons' +, centered on `center` and snapped to the device pixels of `scale`.
    public static func addGlyph(center: CGPoint, scale: CGFloat) -> CGPath {
        let arm = Metrics.addGlyphExtent / 2
        let scale = max(scale, 1)
        let center = CGPoint(x: (center.x * scale).rounded() / scale, y: (center.y * scale).rounded() / scale)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - arm, y: center.y))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        return path
    }
}

extension NSImage {
    /// The add buttons' + as a template image `side` points square (an image button tints it).
    public static func addGlyph(side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = NSGraphicsContext.current.flatMap { $0.cgContext.userSpaceToDeviceSpaceTransform.a } ?? 2
            context.addPath(CGPath.addGlyph(center: CGPoint(x: rect.midX, y: rect.midY), scale: scale))
            context.setLineWidth(Metrics.addGlyphLineWidth)
            context.setLineCap(.round)
            context.setStrokeColor(NSColor.black.cgColor)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
