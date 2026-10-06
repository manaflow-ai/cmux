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
            layer?.backgroundColor = Palette.accent.cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: OnboardingMetrics.bodyFont,
                .foregroundColor: NSColor.white,
            ])
        }
    }
}
