public import AppKit

/// Open and close of a popup window that a control opened (cx-f6i7): the
/// group editors under a tab group chip or a sidebar group header. It fades
/// in while its content grows from `Motion.panelOpenScale` about the middle
/// of its edge that faces the control, so it reads as coming out of that
/// control; it closes faster, fading and shrinking toward the same point.
/// A reopen during the close continues from what is on screen. Reduce
/// Motion keeps the fades only (`Motion.set` snaps the scale).
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

    /// Fades the popup in (its alpha must start at 0 on a fresh open) and
    /// grows its content about `pivot`.
    func openPopup(pivot: CGPoint) {
        guard let content = contentView else { return }
        content.wantsLayer = true
        if let layer = content.layer {
            let closing = layer.animation(forKey: "sublayerTransform") != nil
            Motion.set(layer, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: .appear,
                       from: closing ? nil : NSValue(caTransform3D: Motion.scale(Motion.panelOpenScale, about: pivot, in: layer)))
        }
        Motion.animateTimed(.fadeIn, in: content) { self.animator().alphaValue = 1 }
    }

    /// Fades the popup out while its content shrinks toward `pivot`, then
    /// runs `completion` (which orders it out).
    func closePopup(pivot: CGPoint, completion: @escaping @MainActor () -> Void) {
        guard let content = contentView else { return completion() }
        if let layer = content.layer {
            Motion.set(layer, "sublayerTransform", to: NSValue(caTransform3D: Motion.scale(Motion.panelCloseScale, about: pivot, in: layer)),
                       movementFade: .fadeOut)
        }
        Motion.animateTimed(.fadeOut, in: content, { self.animator().alphaValue = 0 }, completion: completion)
    }

    /// Clears a finished close's scale so the next open starts clean.
    func resetPopupScale() {
        guard let layer = contentView?.layer else { return }
        layer.removeAnimation(forKey: "sublayerTransform")
        layer.sublayerTransform = CATransform3DIdentity
    }
}
