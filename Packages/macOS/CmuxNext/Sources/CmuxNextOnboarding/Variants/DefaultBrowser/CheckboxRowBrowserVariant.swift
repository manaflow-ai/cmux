import AppKit
import CmuxNextDesign

/// A settings-style glass row: one checkbox, "Open links in cmux", with the
/// current state on the right. Checking it asks macOS.
struct CheckboxRowBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.checkbox"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Checkbox Row"
    static let summary = "Opaque; one glass settings row with a checkbox and the current state."
    static let surface = OnboardingSurface.glassControls
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        var style = OnboardingScaffold.Style()
        style.titleSize = 26
        style.titleWeight = .bold
        style.bodyGap = 24
        return OnboardingScaffold.make(title: OnboardingStrings.browserTitle, subtitle: OnboardingStrings.browserSubtitle,
                                       body: CheckboxRowBrowserBody(model: context.model.defaults), context: context, style: style)
    }
}

final class CheckboxRowBrowserBody: BrowserClaimView {
    private let row = FlippedView()
    private let state = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)
    private lazy var box: NSButton = OnboardingControl.checkbox(BrowserVariantStrings.openLinks, target: self, action: #selector(toggled))  // no IUO (crash program)

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        box.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.alignment = .right
        row.addSubview(box)
        row.addSubview(state)
        let glass = Glass.browserVariantPanel(row, cornerRadius: 12)
        addSubview(glass)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            box.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            box.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            state.leadingAnchor.constraint(greaterThanOrEqualTo: box.trailingAnchor, constant: 16),
            state.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            state.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            state.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 12),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        startRendering()
    }

    @objc private func toggled() {
        if box.state == .on { requestClaim() } else { apply(BrowserClaimState(model)) }
    }

    override func apply(_ claim: BrowserClaimState) {
        box.state = claim.choosesCmux ? .on : .off
        box.isEnabled = !claim.choosesCmux
        state.stringValue = claim.statusLine
    }
}
