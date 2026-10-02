import AppKit
import CmuxNextDesign

/// Editorial: the decision on the left, and on the right a quiet well
/// naming the app that opens links now. The well updates when cmux takes over.
struct EditorialSplitBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.editorial"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Editorial Split"
    static let summary = "Left column title and button; right well shows what opens links now."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.none

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let body = EditorialSplitBrowserBody(model: context.model.defaults)
        root.addSubview(body)
        let footer = OnboardingFooter(context: context).pinBrowserFooter(in: root, margin: 48)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 64),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -32),
        ])
        return root
    }
}

final class EditorialSplitBrowserBody: BrowserClaimView {
    private let title = OnboardingLabel.make(OnboardingStrings.browserTitle, font: .systemFont(ofSize: 28, weight: .semibold), lines: 2)
    private let sentence = OnboardingLabel.make(OnboardingStrings.browserSubtitle, color: Palette.textSecondary, lines: 3)
    private let note = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 3)
    private let wellCaption = OnboardingLabel.make(BrowserVariantStrings.opensLinksNow, font: OnboardingMetrics.captionFont,
                                                   color: Palette.textTertiary)
    private let wellName = OnboardingLabel.make(font: .systemFont(ofSize: 22, weight: .semibold))
    private var button: NSButton!

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        button = OnboardingControl.button(OnboardingStrings.makeDefaultBrowser, target: self, action: #selector(requestClaim))
        let column = NSStackView(views: [title, sentence, button, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(28, after: sentence)
        column.setCustomSpacing(12, after: button)
        column.translatesAutoresizingMaskIntoConstraints = false

        let well = ThemedView()
        well.cornerRadius = 12
        well.fill = { Palette.hoverFill }
        well.border = { Palette.separator }
        wellCaption.alignment = .center
        wellName.alignment = .center
        let wellStack = NSStackView(views: [wellCaption, wellName])
        wellStack.orientation = .vertical
        wellStack.alignment = .centerX
        wellStack.spacing = 4
        wellStack.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(wellStack)

        addSubview(column)
        addSubview(well)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5, constant: -16),
            title.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            sentence.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            note.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            // A quiet, fixed-height well level with the title, not a full-height panel.
            well.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            well.heightAnchor.constraint(equalToConstant: 160),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.leadingAnchor.constraint(equalTo: column.trailingAnchor, constant: 32),
            wellStack.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            wellStack.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            wellStack.widthAnchor.constraint(lessThanOrEqualTo: well.widthAnchor, constant: -32),
            wellCaption.widthAnchor.constraint(lessThanOrEqualTo: wellStack.widthAnchor),
            wellName.widthAnchor.constraint(lessThanOrEqualTo: wellStack.widthAnchor),
        ])
        startRendering()
    }

    override func apply(_ state: BrowserClaimState) {
        wellName.stringValue = state.claimed ? "cmux" : (state.current ?? "–")
        button.isHidden = state.claimed
        button.isEnabled = !state.pending
        note.stringValue = state.claimed ? OnboardingStrings.isDefaultBrowser : (state.note ?? "")
        note.isHidden = note.stringValue.isEmpty
    }
}
