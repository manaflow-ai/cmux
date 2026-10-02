import AppKit
import CmuxNextDesign

/// A floating glass card with roomy 56 pt margins: title, sentence, then
/// the button with its status to the right on one line.
struct FloatingCardBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.card"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Floating Card"
    static let summary = "Glass panel, 56 pt margins, button with inline status."
    static let surface = OnboardingSurface.glassPanel
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        var style = OnboardingScaffold.Style()
        style.margin = 56
        style.titleTop = 60
        style.titleSize = 28
        style.bodyGap = 32
        return OnboardingScaffold.make(title: OnboardingStrings.browserTitle, subtitle: OnboardingStrings.browserSubtitle,
                                       body: FloatingCardBrowserBody(model: context.model.defaults), context: context, style: style)
    }
}

final class FloatingCardBrowserBody: BrowserClaimView {
    private let status = OnboardingLabel.make(color: Palette.textSecondary, lines: 2)
    private var button: NSButton!

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        button = OnboardingControl.button(OnboardingStrings.makeDefaultBrowser, prominent: true, target: self, action: #selector(requestClaim))
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [button, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        startRendering()
    }

    override func apply(_ state: BrowserClaimState) {
        button.isHidden = state.claimed
        button.isEnabled = !state.pending
        status.stringValue = state.claimed ? OnboardingStrings.isDefaultBrowser : state.statusLine
    }
}
