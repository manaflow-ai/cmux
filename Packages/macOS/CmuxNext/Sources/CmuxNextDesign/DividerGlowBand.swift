public import AppKit
public import QuartzCore

/// The lit band a resize divider shows while it is hovered or dragged: the line itself in the theme's
/// accent, centered on the divider's line, with no halo, blur or shadow past its edges (Leo,
/// 2026-11-07: "keep the line itself's glow, but don't make it glow like it's an actual light bulb").
/// Nothing shows at rest, so a divider keeps its resting color and thickness; the band only lights
/// the line.
///
/// One instance per divider. It is a pair of plain layers (no timers, no display link): a state
/// change fades the band's opacity once through `Motion.feedback`, which ends on its own and
/// is instant under Reduce Motion, calm mode or animation speed off. Going out is always instant: a
/// pane divider's Chromium hole closes with the state change, so a fading band there would be cut
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

    /// The core's thickness across the divider: the whole band, nothing drawn past it.
    public static let coreThickness: CGFloat = 2
    /// How far the default band (``coreThickness``) reaches from the line's center, on each side: a Chromium hole that
    /// keeps it visible over a page must be this wide each way. A thinner band (`place(along:vertical:thickness:)`)
    /// reaches half its own thickness.
    public static var reach: CGFloat { coreThickness / 2 }

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

    public init() {
        layer.opacity = 0
        layer.masksToBounds = false
        layer.addSublayer(core)
        core.cornerRadius = Self.coreThickness / 2
        // No shadow: the light stays inside the line (no bloom over the panes beside it).
        core.shadowOpacity = 0
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        core.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
    }

    /// Places the band along `line` (the divider's drawn line, in the host layer's coordinates),
    /// centered across it, `thickness` wide (``coreThickness`` by default; a pane split passes its line's own thickness, so
    /// the band never lights the panes beside it). `vertical` is true for a line that runs top to bottom.
    public func place(along line: CGRect, vertical: Bool, thickness: CGFloat = coreThickness) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let t = thickness
        core.cornerRadius = t / 2
        let frame = vertical
            ? CGRect(x: line.midX - t / 2, y: line.minY, width: t, height: line.height)
            : CGRect(x: line.minX, y: line.midY - t / 2, width: line.width, height: t)
        layer.frame = frame
        core.frame = layer.bounds
        CATransaction.commit()
    }

    /// Whether the band is lit (hovered or dragging), from the model state: a Chromium hole that
    /// shows it opens on the change, not after the fade's first frame.
    public var isLit: Bool { state != .rest }

    /// The band's extent across the divider in the host layer's coordinates, as long as the line;
    /// `.null` at rest.
    public var extent: CGRect {
        guard isLit else { return .null }
        return layer.frame
    }

    /// Repaints in the current theme's accent (`Palette.accent`). Call on appearance changes.
    public func applyTheme(_ view: NSView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.performWithTheme {
            core.backgroundColor = Palette.accent.cgColor
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
