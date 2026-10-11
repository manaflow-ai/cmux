public import AppKit

/// The tab drop outline's look, shared by every surface that previews a
/// drop (the layout overlay, the sidebar). Debug Settings tunables.
public nonisolated struct DropOutlineTunables {
    public nonisolated init() {}
    public static let width = Tunable<CGFloat>.number(
        "drop.overlay.outline.width", .dropOverlay, "Outline: width", help: "Width of the border around the drop rect.",
        default: 2, range: 0.5...8, step: 0.25, unit: .points, code: "DropOutlineTunables.width")
    public static let color = Tunable<TunableColor>.color(
        "drop.overlay.outline.color", .dropOverlay, "Outline: color", help: "Theme color of the outline (the accent; no blue).",
        default: .focusRing, code: "DropOutlineTunables.color")

    public static var all: [TunableDescriptor] { [width.descriptor, color.descriptor] }
}

/// A rounded border exactly inside a drop rect, no fill (tab-dnd, Lawrence
/// 2026-10-04: "id rather just draw the border around where it will be
/// dropped"). It moves between rects with a Core Animation spring
/// (`Motion.set`): the compositor draws every frame and the main thread
/// runs no frame clock. Reduce Motion snaps. Add `layer` to a flipped,
/// layer-backed view; rects are in that view's coordinates.
@MainActor
public final class DropOutlineRing {
    public let layer = CALayer()
    /// The rect the ring is at or heading to; nil while hidden.
    public private(set) var rect: CGRect?
    public private(set) var isRefused = false

    public init() {
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "opacity": NSNull(),
                         "borderColor": NSNull(), "borderWidth": NSNull()]
        layer.backgroundColor = nil
        layer.opacity = 0
    }

    /// Moves the ring to `rect` (growing in from `appearInset` of its size
    /// when hidden). `refused` draws it in the danger color.
    public func show(_ rect: CGRect, cornerRadius: CGFloat, refused: Bool = false, animated: Bool,
                     spring: MotionSpring = .track, appearInset: CGFloat = 0.03) {
        Motion.withoutAnimation { layer.borderWidth = DropOutlineTunables.width.value }
        if refused != isRefused || self.rect == nil {
            isRefused = refused
            applyTheme()
        }
        guard self.rect != rect else { return }
        let appearing = self.rect == nil
        if appearing {
            place(rect.insetBy(dx: rect.width * appearInset, dy: rect.height * appearInset), cornerRadius, animated: false, spring)
        }
        place(rect, cornerRadius, animated: animated, spring)
        if appearing || layer.opacity < 1 {
            if animated { Motion.set(layer, "opacity", to: NSNumber(value: 1), fade: .fadeIn) } else { setNow("opacity", NSNumber(value: 1)) }
        }
        self.rect = rect
    }

    public func hide(animated: Bool) {
        guard rect != nil else { return }
        rect = nil
        if animated { Motion.set(layer, "opacity", to: NSNumber(value: 0), fade: .fadeOut) } else { setNow("opacity", NSNumber(value: 0)) }
    }

    /// Re-reads the colors; call inside the host view's theme scope.
    public func applyTheme() {
        let color = isRefused ? Palette.danger : Palette.tunable(DropOutlineTunables.color.value)
        Motion.withoutAnimation { layer.borderColor = color.cgColor }
    }

    private func place(_ rect: CGRect, _ radius: CGFloat, animated: Bool, _ spring: MotionSpring) {
        let bounds = NSValue(rect: CGRect(origin: .zero, size: rect.size))
        let position = NSValue(point: CGPoint(x: rect.midX, y: rect.midY))
        let corner = NSNumber(value: Double(max(0, min(radius, min(rect.width, rect.height) / 2))))
        guard animated else {
            setNow("bounds", bounds)
            setNow("position", position)
            setNow("cornerRadius", corner)
            return
        }
        Motion.set(layer, "bounds", to: bounds, spring: spring)
        Motion.set(layer, "position", to: position, spring: spring)
        Motion.set(layer, "cornerRadius", to: corner, spring: spring)
    }

    private func setNow(_ keyPath: String, _ value: Any) {
        layer.removeAnimation(forKey: keyPath)
        Motion.withoutAnimation { layer.setValue(value, forKeyPath: keyPath) }
    }
}
