import AppKit
import CmuxNextDesign

/// The hover, pressed and keyboard-focus look shared by onboarding's
/// clickable rows and text buttons: a theme-token fill one tonal step up
/// (`hoverFill`, then `pressedFill`) and a `focusRing` outline, faded with
/// the `MotionFade.hover` token. The fill is its own sublayer, drawn
/// `outset` beyond the view's bounds, so nothing moves or resizes when it
/// shows (plans/cmux-next/motion.md). A view that draws its own content
/// (a button's title) uses its backing layer's background instead, which
/// sits under that content.
@MainActor
final class OnboardingHover {
    struct State: Equatable {
        var hovering = false
        var pressed = false
        var focused = false
    }

    private weak var view: NSView?
    private let fill: CALayer
    private let outset: NSSize
    private var tracking: NSTrackingArea?
    var state = State() {
        didSet { if state != oldValue { refresh() } }
    }

    init(_ view: NSView, outset: NSSize = .zero, cornerRadius: CGFloat = Metrics.itemCornerRadius, behindContent: Bool = false) {
        self.view = view
        self.outset = behindContent ? .zero : outset
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
    var drawsBehindContent: Bool { fill === view?.layer }

    /// The fill's color for a state, from theme tokens; nil is no fill.
    static func fillColor(_ state: State) -> NSColor? {
        if state.pressed { return Palette.pressedFill }
        return state.hovering ? Palette.hoverFill : nil
    }

    /// The fill as drawn now (model value), and where it is drawn.
    var shownFill: CGColor? { fill.backgroundColor }
    var fillFrame: CGRect { fill.frame }

    /// Call from the view's `layout()`.
    func layout() {
        guard let view, !drawsBehindContent else { return }
        fill.frame = view.bounds.insetBy(dx: -outset.width, dy: -outset.height)
    }

    /// Call from the view's `updateTrackingAreas()`.
    func updateTrackingAreas() {
        guard let view else { return }
        if let tracking { view.removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: view)
        view.addTrackingArea(area)
        tracking = area
    }

    /// Re-resolves the colors (theme or appearance change) without a fade.
    func refresh(animated: Bool = true) {
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

/// A borderless text button (Skip, Back, Check Again): secondary text that
/// steps up to primary on hover, over the shared hover fill. Keyboard focus
/// draws the gray `focusRing` outline instead of the accent-colored system ring.
/// The frame reaches `padding` past the alignment rect Auto Layout places,
/// so the fill, drawn under the title, extends past the text without
/// moving it.
final class OnboardingTextButton: NSButton {
    static let padding = NSSize(width: 6, height: 3)
    private(set) lazy var hover = OnboardingHover(self, behindContent: true)
    private var plainTitle = ""

    convenience init(_ title: String, target: AnyObject?, action: Selector) {
        self.init(title: title, target: target, action: action)
        plainTitle = title
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        focusRingType = .none
        hover.refresh(animated: false)
        applyTitle()
    }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: Self.padding.height, left: Self.padding.width, bottom: Self.padding.height, right: Self.padding.width)
    }

    private func applyTitle() {
        performWithTheme {
            let color = hover.state.hovering || hover.state.pressed ? Palette.textPrimary : Palette.textSecondary
            attributedTitle = NSAttributedString(string: plainTitle, attributes: [.font: OnboardingMetrics.bodyFont, .foregroundColor: color])
        }
    }

    private func changeHover(_ change: (inout OnboardingHover.State) -> Void) {
        var state = hover.state
        change(&state)
        hover.state = state
        applyTitle()
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { changeHover { $0.hovering = false; $0.pressed = false } } }
    }

    override func layout() {
        super.layout()
        hover.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }

    /// A button hidden under the pointer (Check Again once access is
    /// granted) gets no exit event; it reappears without the fill.
    override func viewDidHide() {
        super.viewDidHide()
        changeHover { $0.hovering = false; $0.pressed = false }
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { changeHover { $0.hovering = true } } }
    override func mouseExited(with event: NSEvent) { changeHover { $0.hovering = false } }

    /// NSButton tracks the click inside `super.mouseDown` and returns on release.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        changeHover { $0.pressed = true }
        super.mouseDown(with: event)
        changeHover { $0.pressed = false }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { changeHover { $0.focused = true } }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { changeHover { $0.focused = false } }
        return resigned
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
        applyTitle()
    }
}
