import AppKit

/// A ``ThemedBezelButton``'s cell: it draws the bezel as the cmux button's own fill (``fills``) instead of
/// AppKit's push bezel, and a disabled title in the button's own inks (``OwnInkButtonCell``).
///
/// AppKit's push bezel takes `bezelColor` only as a tint over its own material, so the ground under the
/// title was neither the theme's fill nor anything the title could be fit to: over a see-through window
/// it read #848484 under Red Planet's #C2B790 title, 1.86:1 (NativeControlContrastAuditTests). A fill the
/// button draws itself is the ground its title is fit over.
final class ThemedBezelButtonCell: OwnInkButtonCell {
    /// The fill at rest and while pressed; nil draws AppKit's own bezel (a checkbox's box).
    var fills: (rest: NSColor, pressed: NSColor)?

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        guard let fills, isBordered else { return super.drawBezel(withFrame: frame, in: controlView) }
        (isHighlighted ? fills.pressed : fills.rest).setFill()
        themedBezelPath(frame, in: controlView).fill()
    }
}

/// The bezel's shape inside `frame`: where AppKit draws its own (the control's alignment rect, which
/// leaves the push bezel's shadow room outside it), rounded as every cmux button is.
@MainActor
func themedBezelPath(_ frame: NSRect, in controlView: NSView) -> NSBezierPath {
    let insets = controlView.alignmentRectInsets
    let rect = NSRect(x: frame.minX + insets.left, y: frame.minY + (controlView.isFlipped ? insets.top : insets.bottom),
                      width: max(0, frame.width - insets.left - insets.right),
                      height: max(0, frame.height - insets.top - insets.bottom))
    let radius = min(Metrics.buttonCornerRadius, rect.height / 2)
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
