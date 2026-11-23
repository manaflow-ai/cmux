import AppKit

/// A ``ThemedPopUpButton``'s cell: it draws the bezel as the cmux button's own fill (``fill``) with its
/// chevron in ``ink``, and the title in ``ink`` instead of AppKit's label ink.
///
/// AppKit's push bezel takes `bezelColor` only as a tint over its own material, so over a see-through
/// window the title read on a gray no ink was fit to (Red Planet, 1.94:1; NativeControlContrastAuditTests).
final class ThemedPopUpButtonCell: NSPopUpButtonCell {
    var ink: NSColor?
    /// The bezel's fill; nil draws AppKit's own bezel and arrows.
    var fill: NSColor?

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard let ink, title.length > 0 else { return super.drawTitle(title, withFrame: frame, in: controlView) }
        let inked = NSMutableAttributedString(attributedString: title)
        inked.addAttribute(.foregroundColor, value: ink, range: NSRange(location: 0, length: inked.length))
        return super.drawTitle(inked, withFrame: frame, in: controlView)
    }

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        guard let fill, let ink, isBordered else { return super.drawBezel(withFrame: frame, in: controlView) }
        let path = themedBezelPath(frame, in: controlView)
        fill.setFill()
        path.fill()
        // The chevron AppKit's bezel drew, in the title's ink: one down for a pull-down menu, up and down for a pop-up.
        let size = (font ?? .systemFont(ofSize: NSFont.systemFontSize)).pointSize * 0.7
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        guard let chevron = NSImage(systemSymbolName: pullsDown ? "chevron.down" : "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return }
        let box = path.bounds
        let origin = NSPoint(x: box.maxX - Metrics.space3 - chevron.size.width, y: box.midY - chevron.size.height / 2)
        chevron.draw(in: NSRect(origin: origin, size: chevron.size), from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
    }
}
