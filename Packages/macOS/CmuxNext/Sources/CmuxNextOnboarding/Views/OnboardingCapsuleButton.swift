import AppKit
import CmuxNextDesign

/// A capsule button for the Computer Use window. `primary` is the one
/// filled action (the theme's accent fill and its ink); `plain` is a quiet
/// gray capsule for the same action on a later row. The style can change
/// in place, so a row's Allow turns primary when the row before it is done.
final class OnboardingCapsuleButton: NSButton {
    enum Style: Equatable { case primary, plain }

    static let height: CGFloat = 28
    private static let horizontalPadding: CGFloat = 14
    private(set) var style: Style
    private var plainTitle: String

    init(title: String, style: Style, target: AnyObject?, action: Selector) {
        self.style = style
        plainTitle = title
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = Self.height / 2
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setStyle(_ next: Style) {
        guard next != style else { return }
        style = next
        applyAppearance()
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + 2 * Self.horizontalPadding, height: Self.height)
    }

    override var isHighlighted: Bool {
        didSet { applyAppearance() }
    }

    /// The window may sit behind System Settings: the first click acts.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func refreshAppearance() { applyAppearance() }

    private func applyAppearance() {
        performWithTheme {
            let fill: NSColor
            let ink: NSColor
            switch style {
            case .primary:
                fill = Palette.accentFill
                ink = Palette.onAccent
            case .plain:
                fill = Palette.textPrimary.withAlphaComponent(0.1)
                ink = Palette.textPrimary
            }
            layer?.backgroundColor = (isHighlighted ? fill.withAlphaComponent(fill.alphaComponent * 0.75) : fill).cgColor
            attributedTitle = NSAttributedString(string: plainTitle, attributes: [
                .font: Typography.system(size: TypeScale.body, weight: TypeScale.regular), .foregroundColor: ink,
            ])
        }
    }
}
