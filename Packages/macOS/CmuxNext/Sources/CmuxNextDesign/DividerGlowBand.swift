public import AppKit
public import QuartzCore

/// The lit band a resize divider shows while it is hovered or dragged: a thin core in the theme's
/// accent with a soft halo around it, centered on the divider's line. Nothing shows at rest, so
/// a divider keeps its resting color and thickness; the band only adds light over it.
///
/// One instance per divider. It is a pair of plain layers (no timers, no display link): a state
/// change fades the band's opacity once through `Motion.feedback`, which ends on its own and
/// is instant under Reduce Motion, calm mode or animation speed off. Going out is always instant: a
/// pane divider's Chromium hole closes with the state change, so a fading halo there would be cut
/// off mid-fade (fading out is optional; opening never waits). There is no pulse or loop.
@MainActor
public final class DividerGlowBand {
    /// How lit the band is.
    public enum State: Equatable, Sendable {
        /// Nothing drawn.
        case rest
        /// The pointer is over the divider: a dimmer band.
        case hovered
        /// A drag runs: the full band.
        case dragging
    }

    /// The core's thickness across the divider.
    public static let coreThickness: CGFloat = 2
    /// The halo's blur radius around the core.
    public static let haloRadius: CGFloat = 3
    /// How far the band reaches from the line's center, on each side: a Chromium hole that keeps
    /// the band visible over a page must be this wide each way.
    public static var reach: CGFloat { coreThickness / 2 + haloRadius }

    /// Opacity of the whole band at each state.
    public static func opacity(_ state: State) -> Float {
        switch state {
        case .rest: 0
        case .hovered: 0.55
        case .dragging: 1
        }
    }

    /// The band's container: add it to the divider's layer, above its line.
    public let layer = CALayer()
    private let core = CALayer()
    public private(set) var state: State = .rest
    private var vertical = true

    public init() {
        layer.opacity = 0
        layer.masksToBounds = false
        layer.addSublayer(core)
        core.cornerRadius = Self.coreThickness / 2
        core.shadowOffset = .zero
        core.shadowRadius = Self.haloRadius
        core.shadowOpacity = 0.9
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        core.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "shadowPath": NSNull(),
                        "backgroundColor": NSNull(), "shadowColor": NSNull()]
    }

    /// Places the band along `line` (the divider's drawn line, in the host layer's coordinates),
    /// centered across it. `vertical` is true for a line that runs top to bottom.
    public func place(along line: CGRect, vertical: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.vertical = vertical
        let t = Self.coreThickness
        let frame = vertical
            ? CGRect(x: line.midX - t / 2, y: line.minY, width: t, height: line.height)
            : CGRect(x: line.minX, y: line.midY - t / 2, width: line.width, height: t)
        layer.frame = frame
        core.frame = layer.bounds
        core.shadowPath = CGPath(roundedRect: core.bounds, cornerWidth: t / 2, cornerHeight: t / 2, transform: nil)
        CATransaction.commit()
    }

    /// Whether the band is lit (hovered or dragging), from the model state: a Chromium hole that
    /// shows it opens on the change, not after the fade's first frame.
    public var isLit: Bool { state != .rest }

    /// The band's extent across the divider (core plus halo) in the host layer's coordinates, as
    /// long as the line; `.null` at rest.
    public var extent: CGRect {
        guard isLit else { return .null }
        let r = Self.haloRadius
        return vertical ? layer.frame.insetBy(dx: -r, dy: 0) : layer.frame.insetBy(dx: 0, dy: -r)
    }

    /// Repaints in the current theme's accent (`Palette.accent`). Call on appearance changes.
    public func applyTheme(_ view: NSView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.performWithTheme {
            core.backgroundColor = Palette.accent.cgColor
            core.shadowColor = Palette.accent.cgColor
        }
        CATransaction.commit()
    }

    /// Lights or dims the band: one fade on `Motion.feedback` (instant when motion is off); back to
    /// rest at once.
    public func set(_ state: State) {
        guard state != self.state else { return }
        self.state = state
        if state == .rest {
            layer.removeAnimation(forKey: "opacity")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 0
            CATransaction.commit()
            return
        }
        Motion.feedback.set(layer, "opacity", to: Self.opacity(state), fade: .hover)
    }
}
