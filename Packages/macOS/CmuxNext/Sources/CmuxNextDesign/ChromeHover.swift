public import AppKit
import QuartzCore

/// The hover, pressed, selected and keyboard-focus look shared by chrome
/// controls (sidebar rows and buttons, tab strip buttons, onboarding rows):
/// a theme-token fill one tonal step per state (`hoverFill`, then
/// `selectionFill`, then `pressedFill`) and a `focusRing` outline, faded as
/// `fade(to:pressed:)` says. The fill is its own sublayer, drawn
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
    /// The pointer hover that sets `state.hovering` (`followPointer`).
    public private(set) var pointer: PointerHover?
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

    /// How a hover or pressed fill reaches `color`, as Edge draws it
    /// (cx-f6i7): nil (at once) for a press, so a quick click always shows;
    /// `hoverOut` as the fill clears (instant by default, so a fast sweep
    /// leaves no trail); `hover`, a fast ease, as it shows or eases back from
    /// a press.
    static func fade(to color: CGColor?, pressed: Bool = false) -> MotionFade? {
        fade(showing: (color?.alpha ?? 0) > 0, pressed: pressed)
    }

    /// `fade(to:pressed:)` for a view that sets its fill inside
    /// `Motion.transaction`: whether the new fill shows at all.
    public static func fade(showing: Bool, pressed: Bool = false) -> MotionFade? {
        pressed ? nil : showing ? .hover : .hoverOut
    }

    /// Sets `layer`'s fill to `color` (nil clears it), fading as
    /// `fade(to:pressed:)` says when `animated`, at once otherwise. For views
    /// that keep their own fill layer (a pill inset in a row). `clearing`
    /// replaces `hoverOut` as the fill clears (sidebar rows fade out too).
    /// Call inside the view's theme scope.
    public static func paint(_ layer: CALayer, _ color: NSColor?, animated: Bool, pressed: Bool = false,
                             clearing: MotionFade = .hoverOut) {
        let target = color?.cgColor
        // A faded-out fill keeps an alpha-0 model value: already clear.
        let shown = color == nil && layer.backgroundColor?.alpha == 0 ? nil : layer.backgroundColor
        guard shown != target else { return }
        guard animated, let token = fade(to: target, pressed: pressed).map({ $0 == .hoverOut ? clearing : $0 }) else {
            layer.removeAnimation(forKey: "backgroundColor")
            Motion.feedback.transaction(nil) { layer.backgroundColor = target }
            return
        }
        // Fade to or from the same color at alpha 0, not to black (a `.clear`
        // rest color is black at alpha 0), starting from what is on screen so
        // a reversal mid-fade never jumps.
        let onScreen = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        let hue = [target, onScreen, layer.backgroundColor].compactMap { $0 }.first { $0.alpha > 0 }
        let clear = hue?.copy(alpha: 0) ?? NSColor.clear.cgColor
        let end = target.flatMap { $0.alpha > 0 ? $0 : nil } ?? clear
        let start = onScreen.flatMap { $0.alpha > 0 ? $0 : nil } ?? clear
        Motion.feedback.set(layer, "backgroundColor", to: end, fade: token, from: start)
    }

    /// Call from the view's `layout()`.
    public func layout() {
        guard let view, !drawsBehindContent else { return }
        fill.frame = view.bounds.insetBy(dx: -outset.width, dy: -outset.height)
    }

    /// `state.hovering` follows the pointer through the shared hover owner
    /// (`PointerHover`): enter and exit, and every geometry or visibility
    /// change (a hide or collapse under a still pointer clears it). The view
    /// sets no hover itself and needs no `updateTrackingAreas` call.
    /// `isHoverable` gates it (a disabled control); `onChange` runs after
    /// the state changes (the view's own colors).
    public func followPointer(isHoverable: @escaping () -> Bool = { true }, onChange: (() -> Void)? = nil) {
        guard let view, pointer == nil else { return }
        if let tracking { view.removeTrackingArea(tracking) }
        tracking = nil
        let pointer = PointerHover(view, requiresKeyWindow: trackingOptions.contains(.activeInKeyWindow))
        pointer.isHoverable = isHoverable
        pointer.onChange = { [weak self] hovering in
            guard let self else { return }
            self.state.hovering = hovering
            onChange?()
        }
        self.pointer = pointer
        pointer.refresh()
    }

    /// Call from the view's `updateTrackingAreas()` (not needed after
    /// `followPointer`).
    public func updateTrackingAreas() {
        guard let view, pointer == nil else { return }
        if let tracking { view.removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, trackingOptions, .inVisibleRect], owner: view)
        view.addTrackingArea(area)
        tracking = area
    }

    /// Applies the state's colors, fading the fill when `animated`; pass
    /// false to re-resolve them at once (theme or appearance change).
    public func refresh(animated: Bool = true) {
        guard let view else { return }
        view.performWithTheme {
            // `paint` eases from the color at alpha 0, so the first hover fades in too.
            Self.paint(fill, Self.fillColor(state), animated: animated, pressed: state.pressed)
            Motion.feedback.transaction(nil) {
                fill.borderColor = Palette.focusRing.cgColor
                fill.borderWidth = state.focused ? Metrics.lineWidth(1.5) : 0
            }
        }
    }
}
