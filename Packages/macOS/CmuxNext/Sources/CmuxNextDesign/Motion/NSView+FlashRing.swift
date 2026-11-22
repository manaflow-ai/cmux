public import AppKit
import QuartzCore

extension NSView {
    /// A brief gray ring over the view (no accent color), the pane flash of Flash Pane: two blinks
    /// (`Motion.flashAnimation`), one fade under Reduce Motion, none when animations are off.
    public func flashRing() {
        guard let host = layer, let fade = Motion.indicators.flashAnimation() else { return }
        let ring = CALayer()
        ring.frame = host.bounds.insetBy(dx: 2, dy: 2)
        ring.cornerRadius = Metrics.paneNestedCornerRadius(inset: 2, size: ring.frame.size)
        let color = performWithTheme { Palette.focusRing }
        if Borders.drawsLines {
            ring.borderWidth = 3
            ring.borderColor = color.cgColor
        } else {
            // appearance.borders none: a soft fill instead of an outline.
            ring.backgroundColor = color.withAlphaComponent(0.18).cgColor
        }
        ring.opacity = 0
        host.addSublayer(ring)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(fade, forKey: "flash")
        CATransaction.commit()
    }
}
