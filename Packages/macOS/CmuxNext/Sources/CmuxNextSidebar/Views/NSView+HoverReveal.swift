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
    /// Shows or hides `view` in its slot, fading with `token` when `fades`
    /// (opacity only). A control fading in takes clicks at once (its alpha is
    /// already 1; only what is drawn fades). A control fading out keeps its
    /// frame and takes no clicks (`hitTest` skips clear buttons); it hides
    /// once the fade ends, unless it came back.
    /// `onHidden` runs once the view is hidden: at once, or when its fade out ends.
    func setHoverShown(_ view: NSView, _ shown: Bool, fades requested: Bool, token: MotionFade = .hover,
                       onHidden: (@MainActor () -> Void)? = nil) {
        // An instant token (Reduce Motion, animations off) shows or hides at once, not after a 0 s fade.
        let fades = requested && Motion.sidebar.duration(token) > 0
        let appears = shown && view.isHidden
        if appears {
            view.alphaValue = fades ? 0 : 1
            view.isHidden = false
        }
        // Hidden, or fading out (its fade hides it).
        guard shown || (!view.isHidden && view.alphaValue > 0) else {
            if !shown, view.isHidden { onHidden?() }
            return
        }
        guard fades else {
            if !shown { view.isHidden = true; onHidden?() }
            if shown, view.alphaValue != 1 { fadeOpacity(view, to: 1, fades: false) }
            return
        }
        CATransaction.begin()
        if !shown {
            CATransaction.setCompletionBlock { [weak view] in // main-proof: CATransaction.h: the completion block is called on the main thread
                MainActor.assumeIsolated {
                    if let view, view.alphaValue == 0 { view.isHidden = true; onHidden?() }
                }
            }
        }
        fadeOpacity(view, to: shown ? 1 : 0, fades: true, from: appears ? 0 : nil, token: token)
        CATransaction.commit()
    }

    /// Shows or hides a trailing slot (`SidebarRevealSlotView`) at `frame`: it fades as
    /// `setHoverShown` does and its width collapses to nothing at its trailing edge (grows from it
    /// on the way in), so the mark leaves no hole and arrives without a jump. A shown slot that
    /// moves (the + and more arriving beside it) slides there with the same token. Instant under
    /// Reduce Motion. While it fades out it keeps `frame`'s place; `onHidden` runs once it is hidden.
    func setHoverSlotShown(_ slot: SidebarRevealSlotView, _ shown: Bool, frame: CGRect, fades requested: Bool,
                           token: MotionFade = .hoverReveal, onHidden: (@MainActor () -> Void)? = nil) {
        let fades = requested && Motion.sidebar.duration(token) > 0
        let wasShown = !slot.isHidden && slot.alphaValue > 0
        let before = slot.layer.map { ($0.presentation() ?? $0).position }
        if shown || !wasShown { slot.frame = frame }
        // The collapse leaves the layer's model narrow; once hidden it gets its resting geometry
        // back, so the next reveal starts from the slot's real frame.
        let rest = slot.layer.map { ($0.bounds, $0.position) }
        setHoverShown(slot, shown, fades: fades, token: token) { [weak slot] in
            if let layer = slot?.layer, let rest {
                layer.removeAnimation(forKey: "bounds")
                layer.removeAnimation(forKey: "position")
                layer.bounds = rest.0
                layer.position = rest.1
            }
            onHidden?()
        }
        guard let layer = slot.layer else { return }
        guard fades else {
            layer.removeAnimation(forKey: "bounds")
            layer.removeAnimation(forKey: "position")
            return
        }
        let full = CGRect(origin: .zero, size: slot.frame.size)
        // Collapsed: no width, its one edge on the slot's trailing edge.
        let collapsed = CGRect(x: full.width, y: 0, width: 0, height: full.height)
        let shift = CGPoint(x: layer.position.x + full.width, y: layer.position.y)
        if shown, !wasShown {
            Motion.sidebar.set(layer, "bounds", to: NSValue(rect: full), movementFade: token, from: NSValue(rect: collapsed))
            Motion.sidebar.set(layer, "position", to: NSValue(point: layer.position), movementFade: token, from: NSValue(point: shift))
        } else if !shown, wasShown {
            Motion.sidebar.set(layer, "bounds", to: NSValue(rect: collapsed), movementFade: token, from: NSValue(rect: full))
            Motion.sidebar.set(layer, "position", to: NSValue(point: shift), movementFade: token, from: NSValue(point: layer.position))
        } else if shown, let before, before != layer.position {
            Motion.sidebar.set(layer, "position", to: NSValue(point: layer.position), movementFade: token, from: NSValue(point: before))
        }
    }

    /// Sets `view`'s alpha, fading when `fades` from `from` or else from what
    /// is on screen, so a reversal mid-fade never jumps.
    func fadeOpacity(_ view: NSView, to alpha: CGFloat, fades: Bool, from: CGFloat? = nil, token: MotionFade = .hover) {
        guard view.alphaValue != alpha || from != nil else { return }
        let shown = from.map { Float($0) } ?? view.layer.map { ($0.presentation() ?? $0).opacity }
        view.alphaValue = alpha
        guard let layer = view.layer else { return }
        guard fades, let shown else { return layer.removeAnimation(forKey: "opacity") }
        Motion.sidebar.set(layer, "opacity", to: Float(alpha), fade: token, from: shown)
    }
}
