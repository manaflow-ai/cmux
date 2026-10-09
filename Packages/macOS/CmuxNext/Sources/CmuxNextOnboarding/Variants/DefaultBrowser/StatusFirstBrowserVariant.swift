import AppKit
import CmuxNextDesign

/// The state is the headline: "Links open in Safari" turns into "Links open
/// in cmux". A small caption names the step; one glass button changes it.
struct StatusFirstBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.status"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Status First"
    static let summary = "Small step caption, the current state as a 28 pt headline, one glass button."
    static let surface = OnboardingSurface.glassControls
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let caption = OnboardingLabel.make(OnboardingStrings.browserTitle, font: .systemFont(ofSize: 13, weight: .semibold),
                                           color: Palette.textSecondary)
        caption.alignment = .center
        let body = StatusFirstBrowserBody(model: context.model.defaults)
        root.addSubview(caption)
        root.addSubview(body)
        let footer = OnboardingFooter(context: context).pinBrowserFooter(in: root, margin: 40)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            caption.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            caption.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -96),
            body.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
        ])
        return root
    }
}

final class StatusFirstBrowserBody: BrowserClaimView {
    private let headline = OnboardingLabel.make(font: .systemFont(ofSize: 28, weight: .regular), lines: 2)
    private let note = OnboardingLabel.make(color: Palette.textSecondary, lines: 2)
    private lazy var button: NSButton = OnboardingControl.button(BrowserVariantStrings.useCmux, prominent: true, target: self, action: #selector(requestClaim))  // no IUO (crash program)
    private lazy var stack: NSStackView = NSStackView(views: [headline, note, button])  // no IUO (crash program)

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        _ = button  // built here, as before
        headline.alignment = .center
        note.alignment = .center
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(28, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            headline.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            note.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        startRendering()
    }

    override func apply(_ state: BrowserClaimState) {
        headline.stringValue = state.headline
        // The headline already reads "Links open in cmux"; the button would repeat it.
        button.isHidden = state.claimed
        button.isEnabled = !state.pending
        note.stringValue = state.note ?? ""
        note.isHidden = state.note == nil
        // A hidden note leaves the stack, so the headline keeps the 28 pt gap to the button.
        stack.setCustomSpacing(state.note == nil ? 28 : 12, after: headline)
    }
}
