import AppKit
import CmuxNextDesign

/// Title and status line only; "Make Default" sits in the footer row
/// beside Continue, so the whole screen is one row of actions.
struct FooterActionBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.footer"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Footer Action"
    static let summary = "Title and status only; Make Default lives in the footer next to Continue."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.none

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let title = OnboardingLabel.make(OnboardingStrings.browserTitle, font: .systemFont(ofSize: 28, weight: .semibold), lines: 2)
        let footer = FooterActionBrowserFooter(context: context)
        let status = FooterActionBrowserStatus(model: context.model.defaults)
        for view in [title, status, footer] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
        ])
        return root
    }
}

/// The status line under the title.
final class FooterActionBrowserStatus: BrowserClaimView {
    private let label = OnboardingLabel.make(color: Palette.textSecondary, lines: 3)

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor), label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor), label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        startRendering()
    }

    override func apply(_ state: BrowserClaimState) {
        label.stringValue = state.claimed ? OnboardingStrings.isDefaultBrowser : state.statusLine
    }
}

/// "2 of 4" on the left; Skip, Make Default and Continue on the right.
final class FooterActionBrowserFooter: BrowserClaimView {
    private let context: OnboardingStepContext
    private var make: NSButton!

    init(context: OnboardingStepContext) {
        self.context = context
        super.init(model: context.model.defaults)
        let counter = OnboardingLabel.make(OnboardingStrings.stepCounter(context.index + 1, context.count),
                                           font: OnboardingMetrics.captionFont, color: Palette.textTertiary)
        counter.isHidden = !OnboardingFooter.showsCounter(count: context.count)
        let skip = OnboardingControl.plainButton(OnboardingStrings.skip, target: self, action: #selector(skipPressed))
        make = OnboardingControl.button(BrowserVariantStrings.makeDefault, target: self, action: #selector(requestClaim))
        let next = OnboardingControl.button(context.isLast ? OnboardingStrings.done : OnboardingStrings.continueButton,
                                            prominent: true, target: self, action: #selector(nextPressed))
        let actions = NSStackView(views: [skip, make, next])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 12
        actions.setCustomSpacing(20, after: skip)
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(counter)
        addSubview(actions)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            counter.leadingAnchor.constraint(equalTo: leadingAnchor), counter.centerYAnchor.constraint(equalTo: centerYAnchor),
            counter.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -16),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor), actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        startRendering()
    }

    @objc private func skipPressed() { context.skip() }
    @objc private func nextPressed() { context.next() }

    override func apply(_ state: BrowserClaimState) {
        make.isHidden = state.claimed
        make.isEnabled = !state.pending
    }
}
