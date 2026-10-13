import AppKit
import QuartzCore

extension NSView {
    /// Fades the view's trailing `occlusion` points out (an alpha mask, so it
    /// works over every theme and translucent backdrop): clear under the
    /// workspace row's hover actions, with a `fade` long ramp before them
    /// (Lawrence 2026-10-11, cx-qno.22: "Overlay with fade"). Zero removes the mask.
    func setTrailingFade(occlusion: CGFloat, fade: CGFloat) {
        guard let layer else { return }
        guard occlusion > 0, bounds.width > 0 else {
            layer.mask = nil
            return
        }
        let mask = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull(), "colors": NSNull()]
        mask.frame = layer.bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let clear = max(0, bounds.width - occlusion)
        let start = max(0, clear - fade)
        mask.locations = [0, NSNumber(value: Double(start / bounds.width)), NSNumber(value: Double(clear / bounds.width))]
        layer.mask = mask
    }
}
