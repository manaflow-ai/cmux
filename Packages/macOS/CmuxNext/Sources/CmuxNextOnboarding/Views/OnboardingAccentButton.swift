import AppKit
import CmuxNextDesign

/// The import action's filled button. It keeps the primary action legible on
/// the glass surface without the capsule shape used by system glass buttons.
final class OnboardingAccentButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        controlSize = .large
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 6
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func refreshAppearance() {
        applyAppearance()
    }

    private func applyAppearance() {
        performWithTheme {
            // `highlightText` is derived with ThemeTokens.minimumTextContrast
            // (4.5:1), so the action fill stays readable in every theme.
            layer?.backgroundColor = Palette.highlight.cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: OnboardingMetrics.bodyFont,
                .foregroundColor: Palette.highlightText,
            ])
        }
    }
}
