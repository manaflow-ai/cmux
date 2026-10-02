public import AppKit
import QuartzCore

/// The hover, pressed, selected and keyboard-focus look shared by chrome
/// controls (sidebar rows and buttons, tab strip buttons, onboarding rows):
/// a theme-token fill one tonal step per state (`hoverFill`, then
/// `selectionFill`, then `pressedFill`) and a `focusRing` outline, faded with
/// the `MotionFade.hover` token. The fill is its own sublayer, drawn
/// `outset` beyond the view's bounds, so nothing moves or resizes when it
/// shows (plans/cmux-next/motion.md). A view that draws its own content
/// (a button's title) uses its backing layer's background instead, which
/// sits under that content.
@MainActor
public final class ChromeHover {
    public struct State: Equatable {
        public var hovering: Bool
        public var pressed: Bool
        public var focused: Bool
        /// The control is the current one (an active item); hover adds nothing.
        public var selected: Bool

        public init(hovering: Bool = false, pressed: Bool = false, focused: Bool = false, selected: Bool = false) {
            self.hovering = hovering
            self.pressed = pressed
            self.focused = focused
            self.selected = selected
        }
    }

    private weak var view: NSView?
    private let fill: CALayer
    private let outset: NSSize
    private let trackingOptions: NSTrackingArea.Options
    private var tracking: NSTrackingArea?
    public var state = State() {
        didSet { if state != oldValue { refresh() } }
    }

    /// - Parameter tracking: `.activeAlways` for window chrome (hover shows
    ///   in a background window, as in the sidebar), `.activeInKeyWindow`
    ///   for sheets and onboarding.
    public init(_ view: NSView, outset: NSSize = .zero, cornerRadius: CGFloat = Metrics.itemCornerRadius, behindContent: Bool = false,
                tracking: NSTrackingArea.Options = .activeAlways) {
        self.view = view
        self.outset = behindContent ? .zero : outset
        trackingOptions = tracking
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        fill = behindContent ? (view.layer ?? CALayer()) : CALayer()
        fill.cornerRadius = cornerRadius
        fill.cornerCurve = .continuous
        guard !behindContent else { return }
        fill.actions = ["bounds": NSNull(), "position": NSNull()]
        view.layer?.insertSublayer(fill, at: 0)
    }

    /// Whether the fill is the view's own backing layer (under its content).
    public var drawsBehindContent: Bool { fill === view?.layer }

    /// The fill's color for a state, from theme tokens; `rest` when idle
    /// (a tile's faint fill), nil for no fill. Pressed wins over selected,
    /// selected over hovered. Focus is an outline, never a fill.
    public static func fillColor(_ state: State, rest: NSColor? = nil) -> NSColor? {
        if state.pressed { return Palette.pressedFill }
        if state.selected { return Palette.selectionFill }
        return state.hovering ? Palette.hoverFill : rest
    }

    /// Sets `layer`'s fill to `color` (nil clears it), fading with
    /// `MotionFade.hover` when `animated`, at once otherwise. For views that
    /// keep their own fill layer (a pill inset in a row). Call inside the
    /// view's theme scope.
    public static func paint(_ layer: CALayer, _ color: NSColor?, animated: Bool) {
        let target = color?.cgColor
        guard layer.backgroundColor != target else { return }
        guard animated else {
            layer.removeAnimation(forKey: "backgroundColor")
            Motion.transaction(nil) { layer.backgroundColor = target }
            return
        }
        // Fade to or from the same color at alpha 0, not to black, then
        // leave no fill once it is gone.
        let clear = (color ?? layer.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear).withAlphaComponent(0).cgColor
        Motion.set(layer, "backgroundColor", to: target ?? clear, fade: .hover, from: layer.backgroundColor ?? clear)
    }

    /// The fill as drawn now (model value), and where it is drawn.
    public var shownFill: CGColor? { fill.backgroundColor }
    public var fillFrame: CGRect { fill.frame }

    /// Call from the view's `layout()`.
    public func layout() {
        guard let view, !drawsBehindContent else { return }
        fill.frame = view.bounds.insetBy(dx: -outset.width, dy: -outset.height)
    }

    /// Call from the view's `updateTrackingAreas()`.
    public func updateTrackingAreas() {
        guard let view else { return }
        if let tracking { view.removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, trackingOptions, .inVisibleRect], owner: view)
        view.addTrackingArea(area)
        tracking = area
    }

    /// Re-resolves the colors (theme or appearance change) without a fade.
    public func refresh(animated: Bool = true) {
        guard let view else { return }
        view.performWithTheme {
            let color = (Self.fillColor(state) ?? .clear).cgColor
            if animated {
                Motion.set(fill, "backgroundColor", to: color, fade: .hover)
            } else {
                Motion.transaction(nil) { fill.backgroundColor = color }
            }
            Motion.transaction(nil) {
                fill.borderColor = Palette.focusRing.cgColor
                fill.borderWidth = state.focused ? Metrics.lineWidth(1.5) : 0
            }
        }
    }
}
