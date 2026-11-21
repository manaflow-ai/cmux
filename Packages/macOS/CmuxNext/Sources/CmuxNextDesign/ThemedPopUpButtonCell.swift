import AppKit

/// Draws the pop-up's title in ``ink`` (the theme's, set by ``ThemedPopUpButton``) instead of AppKit's label ink.
final class ThemedPopUpButtonCell: NSPopUpButtonCell {
    var ink: NSColor?

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard let ink, title.length > 0 else { return super.drawTitle(title, withFrame: frame, in: controlView) }
        let inked = NSMutableAttributedString(attributedString: title)
        inked.addAttribute(.foregroundColor, value: ink, range: NSRange(location: 0, length: inked.length))
        return super.drawTitle(inked, withFrame: frame, in: controlView)
    }
}
