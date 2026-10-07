import AppKit
import CmuxNextDesign

/// A borderless text button (Skip, Back, Check Again): secondary text that
/// steps up to primary on hover, over the shared hover fill. Keyboard focus
/// draws the gray `focusRing` outline instead of the accent-colored system ring.
/// The frame reaches `padding` past the alignment rect Auto Layout places,
/// so the fill, drawn under the title, extends past the text without
/// moving it.
final class OnboardingTextButton: NSButton {
    static let padding = NSSize(width: 6, height: 3)
    private(set) lazy var hover = ChromeHover(self, behindContent: true, tracking: .activeInKeyWindow)
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

    private func changeHover(_ change: (inout ChromeHover.State) -> Void) {
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
