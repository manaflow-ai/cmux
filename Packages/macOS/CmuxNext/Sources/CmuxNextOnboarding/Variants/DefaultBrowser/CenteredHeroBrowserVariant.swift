import AppKit
import CmuxNextDesign

/// One large centered line and one large glass button, nothing else.
struct CenteredHeroBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.hero"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Centered Hero"
    static let summary = "34 pt centered title, one extra-large glass button, status under it."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let body = CenteredHeroBrowserBody(model: context.model.defaults)
        root.addSubview(body)
        let footer = OnboardingFooter(context: context).pinBrowserFooter(in: root, margin: 40)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
        ])
        return root
    }
}

final class CenteredHeroBrowserBody: BrowserClaimView {
    private let title = OnboardingLabel.make(BrowserVariantStrings.openLinks, font: .systemFont(ofSize: 34, weight: .bold), lines: 2)
    private let status = OnboardingLabel.make(font: .systemFont(ofSize: 13), color: Palette.textSecondary, lines: 2)
    private var button: NSButton!

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        button = .browserHeroButton(OnboardingStrings.makeDefaultBrowser, target: self, action: #selector(requestClaim))
        title.alignment = .center
        status.alignment = .center
        let stack = NSStackView(views: [title, button, status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(36, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // Optically centered: a little above the true center.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        startRendering()
    }

    override func apply(_ state: BrowserClaimState) {
        button.isHidden = state.claimed
        button.isEnabled = !state.pending
        status.stringValue = state.claimed ? OnboardingStrings.isDefaultBrowser : state.statusLine
    }
}
