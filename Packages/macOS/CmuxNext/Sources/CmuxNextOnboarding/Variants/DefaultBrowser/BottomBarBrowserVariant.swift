import AppKit
import CmuxNextDesign

/// Title up top, calm space, and the decision anchored above the footer:
/// a glass bar with the current state on the left and the button on the right.
struct BottomBarBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.bottomBar"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Bottom Bar"
    static let summary = "Opaque; title top-left, glass bar above the footer with status and button."
    static let surface = OnboardingSurface.glassControls
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let title = OnboardingLabel.make(OnboardingStrings.browserTitle, font: .systemFont(ofSize: 22, weight: .semibold), lines: 2)
        let sentence = OnboardingLabel.make(OnboardingStrings.browserSubtitle, color: Palette.textSecondary, lines: 2)
        let bar = BottomBarBrowserBar(model: context.model.defaults)
        let glass = Glass.browserVariantPanel(bar, cornerRadius: 12)
        for view in [title, sentence, glass] as [NSView] { root.addSubview(view) }
        let footer = OnboardingFooter(context: context).pinBrowserFooter(in: root, margin: 40)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40),
            sentence.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            sentence.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            sentence.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40),
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            glass.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -24),
            glass.topAnchor.constraint(greaterThanOrEqualTo: sentence.bottomAnchor, constant: 24),
        ])
        return root
    }
}

final class BottomBarBrowserBar: BrowserClaimView {
    private let status = OnboardingLabel.make(lines: 2)
    private lazy var button: NSButton = OnboardingControl.button(OnboardingStrings.makeDefaultBrowser, target: self, action: #selector(requestClaim))  // no IUO (crash program)

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(status)
        addSubview(button)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            status.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        startRendering()
    }

    override func apply(_ state: BrowserClaimState) {
        status.stringValue = state.statusLine
        button.isHidden = state.claimed
        button.isEnabled = !state.pending
    }
}
