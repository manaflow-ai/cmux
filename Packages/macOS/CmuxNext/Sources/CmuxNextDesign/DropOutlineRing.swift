public import AppKit
public import CmuxNextDesignTokens

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

    /// Classic cmux fills the drop rect with the accent at 0.25 under the
    /// 2 pt accent border (pane-drop-targets DESIGN.md). Surfaces that ask
    /// for a fill (the layout overlay) use this; the sidebar ring stays
    /// border-only.
    public static let fillOpacity = Tunable<CGFloat>.number(
        "drop.overlay.outline.fillOpacity", .dropOverlay, "Outline: fill", help: "Opacity of the outline color inside the drop rect (0: border only).",
        default: 0.25, range: 0...1, step: 0.05, unit: .fraction, code: "DropOutlineTunables.fillOpacity")

    public static var all: [TunableDescriptor] { [width.descriptor, color.descriptor, fillOpacity.descriptor] }
}

/// A rounded border exactly inside a drop rect (tab-dnd, Lawrence
/// 2026-10-04: "id rather just draw the border around where it will be
/// dropped"), with an optional fill of the same color (`fillOpacity`; the
/// layout overlay asks for classic's 0.25). It moves between rects with a Core Animation spring
/// (`Motion.set`): the compositor draws every frame and the main thread
/// runs no frame clock. Reduce Motion snaps. Add `layer` to a flipped,
/// layer-backed view; rects are in that view's coordinates.
@MainActor
public final class DropOutlineRing {
    public let layer = CALayer()
    /// The rect the ring is at or heading to; nil while hidden.
    public private(set) var rect: CGRect?
    public private(set) var isRefused = false
    /// Opacity of the ring color filling the rect (0: no fill).
    public private(set) var fillOpacity: CGFloat = 0

    /// How the ring's moves run on Core Animation.
    public enum Springs {
        /// A spring from the presented value that replaces the running one (`MotionGate.set`).
        case replacing
        /// Additive `RenderSpring` retargets: the velocity carries over and nothing reads the
        /// presentation layer. `shownIn` is the view that shows the ring.
        case additive(shownIn: NSView)
    }

    /// The key paths a move springs.
    private static let movedKeyPaths = ["bounds", "position", "cornerRadius"]

    public init() {
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "opacity": NSNull(),
                         "borderColor": NSNull(), "borderWidth": NSNull()]
        layer.backgroundColor = nil
        layer.opacity = 0
    }

    /// Moves the ring to `rect` (growing in from `appearInset` of its size
    /// when hidden). `refused` draws it in the danger color.
    public func show(_ rect: CGRect, cornerRadius: CGFloat, refused: Bool = false, animated: Bool,
                     spring: MotionSpring = .track, appearInset: CGFloat = 0.03, fillOpacity: CGFloat = 0,
                     springs: Springs = .replacing) {
        Motion.withoutAnimation { layer.borderWidth = DropOutlineTunables.width.value }
        if refused != isRefused || self.rect == nil || fillOpacity != self.fillOpacity {
            isRefused = refused
            self.fillOpacity = fillOpacity
            applyTheme()
        }
        guard self.rect != rect else { return }
        let appearing = self.rect == nil
        if appearing {
            place(rect.insetBy(dx: rect.width * appearInset, dy: rect.height * appearInset), cornerRadius, animated: false, spring, springs)
        }
        place(rect, cornerRadius, animated: animated, spring, springs)
        if appearing || layer.opacity < 1 {
            if animated { Motion.panes.set(layer, "opacity", to: NSNumber(value: 1), fade: .fadeIn) } else { setNow("opacity", NSNumber(value: 1)) }
        }
        self.rect = rect
    }

    public func hide(animated: Bool) {
        guard rect != nil else { return }
        rect = nil
        if animated { Motion.panes.set(layer, "opacity", to: NSNumber(value: 0), fade: .fadeOut) } else { setNow("opacity", NSNumber(value: 0)) }
    }

    /// Re-reads the colors; call inside the host view's theme scope.
    public func applyTheme() {
        let color = isRefused ? Palette.danger : Palette.tunable(DropOutlineTunables.color.value)
        Motion.withoutAnimation {
            layer.borderColor = color.cgColor
            layer.backgroundColor = fillOpacity > 0 ? color.withAlphaComponent(color.alphaComponent * fillOpacity).cgColor : nil
        }
    }

    private func place(_ rect: CGRect, _ radius: CGFloat, animated: Bool, _ spring: MotionSpring, _ springs: Springs) {
        let size = rect.size, center = CGPoint(x: rect.midX, y: rect.midY)
        let corner = max(0, min(radius, min(rect.width, rect.height) / 2))
        let bounds = NSValue(rect: CGRect(origin: .zero, size: size))
        let position = NSValue(point: center)
        let cornerValue = NSNumber(value: Double(corner))
        guard animated else {
            setNow("bounds", bounds)
            setNow("position", position)
            setNow("cornerRadius", cornerValue)
            return
        }
        switch springs {
        case .replacing:
            // An additive spring left on a key path would add to the replacing one's value.
            for keyPath in Self.movedKeyPaths { RenderSpring.stop(layer, keyPath) }
            Motion.panes.set(layer, "bounds", to: bounds, spring: spring)
            Motion.panes.set(layer, "position", to: position, spring: spring)
            Motion.panes.set(layer, "cornerRadius", to: cornerValue, spring: spring)
        case .additive(let view):
            // A replacing spring would pin the presented value to its own end (`RenderSpring`).
            for keyPath in Self.movedKeyPaths { layer.removeAnimation(forKey: keyPath) }
            Motion.panes.renderSpring(spring).animateGroup([
                RenderSpring.Move(layer, .boundsSize, to: size),
                RenderSpring.Move(layer, .position, to: center),
                RenderSpring.Move(layer, .cornerRadius, to: corner),
            ], in: view)
        }
    }

    private func setNow(_ keyPath: String, _ value: Any) {
        RenderSpring.stop(layer, keyPath)
        layer.removeAnimation(forKey: keyPath)
        Motion.withoutAnimation { layer.setValue(value, forKeyPath: keyPath) }
    }
}
