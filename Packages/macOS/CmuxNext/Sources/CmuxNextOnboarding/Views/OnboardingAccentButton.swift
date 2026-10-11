import AppKit
import CmuxNextDesign

/// Onboarding's filled primary button (Continue, Done, Import). It keeps the
/// primary action legible on the glass surface without the capsule shape used
/// by system glass buttons, in the theme's own colors.
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
            // The theme's own foreground as the fill and its background as
            // the text: never a blue. `Palette.highlight` is the theme's ANSI
            // blue, which is blue in most themes (lead rule: no blue).
            layer?.backgroundColor = Palette.textPrimary.cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: OnboardingMetrics.bodyFont,
                .foregroundColor: Palette.textOnPrimary,
            ])
        }
    }
}
