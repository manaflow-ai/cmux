import AppKit
import CmuxNextDesign
import QuartzCore

/// The sidebar's one hover-reveal (Leo 2026-10-13, cosmic-gray): a hover
/// control (a row's x, menu button, pin, tab chevron and the unread badge they
/// replace; the Now Playing card's x) reveals in its own slot with the
/// `.hover` fade and clears with the same short transition, instant under
/// Reduce Motion (the token's duration is 0 there). The marks it covers stay
/// in place, so nothing moves or resizes. Layouts that hover did not cause
/// (reloads, recycling, theme) apply at once.
extension NSView {
    /// Shows or hides `view` in its slot, fading when `fades`. A control
    /// fading out keeps its frame and takes no clicks (`hitTest` skips clear
    /// buttons); it hides once the fade ends, unless it came back.
    func setHoverShown(_ view: NSView, _ shown: Bool, fades: Bool) {
        let appears = shown && view.isHidden
        if appears {
            view.alphaValue = fades ? 0 : 1
            view.isHidden = false
        }
        // Hidden, or fading out (its fade hides it).
        guard shown || (!view.isHidden && view.alphaValue > 0) else { return }
        guard fades else {
            if !shown { view.isHidden = true }
            if shown, view.alphaValue != 1 { fadeOpacity(view, to: 1, fades: false) }
            return
        }
        CATransaction.begin()
        if !shown {
            CATransaction.setCompletionBlock { [weak view] in // main-proof: CATransaction.h: the completion block is called on the main thread
                MainActor.assumeIsolated {
                    if let view, view.alphaValue == 0 { view.isHidden = true }
                }
            }
        }
        fadeOpacity(view, to: shown ? 1 : 0, fades: true, from: appears ? 0 : nil)
        CATransaction.commit()
    }

    /// Sets `view`'s alpha, fading when `fades` from `from` or else from what
    /// is on screen, so a reversal mid-fade never jumps.
    func fadeOpacity(_ view: NSView, to alpha: CGFloat, fades: Bool, from: CGFloat? = nil) {
        guard view.alphaValue != alpha || from != nil else { return }
        let shown = from.map { Float($0) } ?? view.layer.map { ($0.presentation() ?? $0).opacity }
        view.alphaValue = alpha
        guard let layer = view.layer else { return }
        guard fades, let shown else { return layer.removeAnimation(forKey: "opacity") }
        Motion.set(layer, "opacity", to: Float(alpha), fade: .hover, from: shown)
    }
}
