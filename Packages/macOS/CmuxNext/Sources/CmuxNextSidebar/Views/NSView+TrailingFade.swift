import AppKit
import CmuxNextDesign
import QuartzCore

extension NSView {
    /// Fades the view's trailing `occlusion` points out (an alpha mask, so it
    /// works over every theme and translucent backdrop): clear under the
    /// workspace row's hover actions, with a `fade` long ramp before them
    /// (Lawrence 2026-10-11, cx-qno.22: "Overlay with fade"). Zero removes the mask.
    /// `animated` eases the stops (Motion `hover`) as the actions fade in or
    /// out; at zero the mask eases fully open instead, and the next layout
    /// that is not animated removes it.
    func setTrailingFade(occlusion: CGFloat, fade: CGFloat, animated: Bool = false) {
        guard let layer else { return }
        let current = layer.mask as? CAGradientLayer
        let open: [NSNumber] = [0, 1, 1]
        guard bounds.width > 0, occlusion > 0 || (animated && current != nil) else {
            layer.mask = nil
            return
        }
        let mask = current ?? CAGradientLayer()
        mask.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull(), "colors": NSNull()]
        mask.frame = layer.bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let clear = max(0, bounds.width - occlusion)
        let start = max(0, clear - fade)
        let locations = occlusion > 0 ? [0, NSNumber(value: Double(start / bounds.width)), NSNumber(value: Double(clear / bounds.width))] : open
        if animated, mask.locations != locations {
            // A line that had no mask starts fully shown.
            Motion.sidebar.set(mask, "locations", to: locations, fade: .hover, from: current == nil ? open : nil)
        } else {
            mask.removeAnimation(forKey: "locations")
            mask.locations = locations
        }
        layer.mask = mask
    }
}
