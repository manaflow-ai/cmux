public import AppKit

/// Open and close of a popup window that a control opened (cx-f6i7): the
/// Chief pill's settings card, the group editors under a tab group chip or a
/// sidebar group header, page info, the toolbar menus. The card fades in
/// while it grows from `Motion.popupOpenScale` on the `popover` spring about
/// the middle of its edge that faces the control, so it reads as coming out
/// of that control; it closes faster (`popoverClose`), fading and shrinking
/// toward the same point. A reopen during the close continues from what is
/// on screen. Reduce Motion keeps a short crossfade at the popup's size;
/// `ui.animationSpeed` "off" applies both at once.
///
/// Both run on the content view's layer, never the window's alpha
/// (Lawrence's recording 2026-10-20): faded through `alphaValue`, the glass
/// card showed no fade at all, so it appeared at full size in one frame and
/// left after a ~75 ms hold. The window is opaque while the popup is up;
/// owners still order a fresh popup front at alpha 0, which `openPopup`
/// lifts once the card's layer starts at opacity 0, so nothing flashes.
@MainActor
public extension NSWindow {
    /// The point the popup grows from, in its content view: the middle of
    /// the content edge nearest `anchor` (screen coordinates), at the
    /// anchor's horizontal center when that falls inside the popup.
    func popupPivot(toward anchor: CGRect) -> CGPoint {
        let bounds = contentView?.bounds ?? CGRect(origin: .zero, size: frame.size)
        let x = min(max(anchor.midX - frame.minX, bounds.minX), bounds.maxX)
        // Window content is y-up: an anchor above the popup pivots on its top edge.
        let y = anchor.midY >= frame.midY ? bounds.maxY : bounds.minY
        return CGPoint(x: x, y: y)
    }

    /// Opens the popup at `pivot`. Popups use their shared entrance motion by
    /// default; menu callers opt out explicitly so they appear in one frame. A
    /// fresh animated open (the owner left the window at alpha 0) starts from
    /// nothing; a reopen during the close continues from what is on screen.
    func openPopup(pivot: CGPoint, entrance: Bool = true) {
        guard entrance else { return showPopupAtOnce() }
        guard let content = contentView else {
            alphaValue = 1
            return
        }
        content.wantsLayer = true
        guard let layer = content.layer else {
            alphaValue = 1
            return
        }
        let reopening = layer.animation(forKey: "opacity") != nil || layer.animation(forKey: "sublayerTransform") != nil
        let fresh = !reopening && alphaValue < 1
        guard Motion.canAnimate(in: content) else { return showPopupAtOnce() }
        Motion.overlays.set(layer, "opacity", to: NSNumber(value: Float(1)), fade: .fadeIn,
                   from: fresh ? NSNumber(value: Float(0)) : nil)
        if Motion.overlays.animatesMovement {
            Motion.overlays.set(layer, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: .popover,
                       from: fresh ? NSValue(caTransform3D: Motion.scale(Motion.popupOpenScale, about: pivot, in: layer)) : nil)
        } else {
            // Reduce Motion: at the popup's size, whatever a close left on screen.
            layer.removeAnimation(forKey: "sublayerTransform")
            setPopupLayer(layer, opacity: nil, transform: CATransform3DIdentity)
        }
        // The card's first frame (opacity 0) reaches the screen before the window turns opaque.
        // perf-gate-ok: one commit per popup open (no flash of the full card); a theme change never opens one.
        CATransaction.flush()
        alphaValue = 1
    }

    /// Shows the popup's card at its size and full opacity in this frame, ending any open or close
    /// on screen: the open with no entrance (a page that asks for none, the New Tab; or no motion).
    func showPopupAtOnce() {
        if let content = contentView {
            content.wantsLayer = true
            if let layer = content.layer {
                layer.removeAnimation(forKey: "opacity")
                layer.removeAnimation(forKey: "sublayerTransform")
                setPopupLayer(layer, opacity: 1, transform: CATransform3DIdentity)
            }
        }
        alphaValue = 1
    }

    /// Fades the popup's card out while it shrinks toward `pivot`, then
    /// runs `completion` (which orders it out and calls ``resetPopupScale()``).
    func closePopup(pivot: CGPoint, completion: @escaping @MainActor () -> Void) {
        guard let content = contentView, let layer = content.layer, Motion.canAnimate(in: content) else {
            alphaValue = 0
            return completion()
        }
        let duration = Motion.overlays.animatesMovement ? Motion.overlays.duration(.popoverClose) : Motion.overlays.duration(.fadeOut)
        guard duration > 0 else {
            layer.removeAnimation(forKey: "opacity")
            layer.removeAnimation(forKey: "sublayerTransform")
            setPopupLayer(layer, opacity: 0, transform: nil)
            return completion()
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } } // main-proof: CATransaction.h: the completion block is called on the main thread
        Motion.overlays.set(layer, "opacity", to: NSNumber(value: Float(0)), duration: duration)
        if Motion.overlays.animatesMovement {
            Motion.overlays.set(layer, "sublayerTransform", to: NSValue(caTransform3D: Motion.scale(Motion.popupCloseScale, about: pivot, in: layer)),
                       duration: duration)
        } else {
            layer.removeAnimation(forKey: "sublayerTransform")
        }
        CATransaction.commit()
    }

    /// Clears a finished close (the card's fade and scale) so the next open starts clean.
    func resetPopupScale() {
        guard let layer = contentView?.layer else { return }
        layer.removeAnimation(forKey: "sublayerTransform")
        layer.removeAnimation(forKey: "opacity")
        setPopupLayer(layer, opacity: 1, transform: CATransform3DIdentity)
    }

    /// Writes the card layer's model values without an implicit animation.
    private func setPopupLayer(_ layer: CALayer, opacity: Float?, transform: CATransform3D?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let opacity { layer.opacity = opacity }
        if let transform { layer.sublayerTransform = transform }
        CATransaction.commit()
    }
}

/// One popup window's open and close (`openPopup` / `closePopup`) for an
/// owner that shows and hides it: a close that ends after a reopen leaves
/// the popup up, and a close ends even when its owner is gone by then.
@MainActor
public final class PopupFade {
    /// A close is fading the popup out; it counts as closed.
    public private(set) var isClosing = false
    private var generation = 0

    public init() {}

    /// Shows `window` (already placed) over `parent`, growing out of
    /// `anchor` (screen coordinates); a reopen during the close continues
    /// from what is on screen.
    public func open(_ window: NSWindow, over parent: NSWindow, toward anchor: CGRect) {
        generation += 1
        let opening = !window.isVisible || isClosing
        isClosing = false
        window.ignoresMouseEvents = false
        if !window.isVisible { window.alphaValue = 0 }
        if window.parent !== parent {
            window.parent?.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .above)
        }
        window.orderFront(nil)
        // The icon picker is a menu-like control: the instant-menu rule applies
        // even though PopupFade also services animated card panels.
        if opening { window.openPopup(pivot: window.popupPivot(toward: anchor), entrance: false) }
    }

    /// Fades `window` out toward `anchor`, then takes it off its window.
    /// Keys and clicks go back to the window under it now, not when the
    /// fade ends (like `SidebarGroupEditor.dismiss`).
    public func close(_ window: NSWindow, toward anchor: CGRect) {
        guard window.isVisible, !isClosing else { return }
        window.ignoresMouseEvents = true
        window.makeFirstResponder(nil)
        if window.isKeyWindow, let parent = window.parent, parent.isVisible { parent.makeKey() }
        generation += 1
        isClosing = true
        let closing = generation
        window.closePopup(pivot: window.popupPivot(toward: anchor)) { [self, window] in
            guard generation == closing else { return }
            isClosing = false
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
            window.resetPopupScale()
        }
    }
}
