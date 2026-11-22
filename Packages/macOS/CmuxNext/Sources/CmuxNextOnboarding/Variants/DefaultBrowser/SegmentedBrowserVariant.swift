import AppKit
import CmuxNextDesign

/// The choice as one large segmented control, "Use cmux | Keep Safari",
/// centered under a title. No sentence.
struct SegmentedBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.segmented"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Segmented"
    static let summary = "Centered 28 pt title, a large two-segment choice, no sentence."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let body = SegmentedBrowserBody(model: context.model.defaults)
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

final class SegmentedBrowserBody: BrowserClaimView {
    private let title = OnboardingLabel.make(OnboardingStrings.browserTitle, font: .systemFont(ofSize: 28, weight: .semibold), lines: 2)
    private let note = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)
    private let control = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        title.alignment = .center
        note.alignment = .center
        control.target = self
        control.action = #selector(changed)
        control.controlSize = .large
        control.segmentDistribution = .fillEqually
        control.selectedSegmentBezelColor = Palette.selectionFill
        control.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, control, note])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(32, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            note.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            control.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        startRendering()
    }

    @objc private func changed() {
        let state = BrowserClaimState(model)
        // macOS owns switching back; a click on Keep after the claim snaps back.
        if control.selectedSegment == 0, !state.claimed { requestClaim() } else { apply(state) }
    }

    override func apply(_ state: BrowserClaimState) {
        control.setLabel(BrowserVariantStrings.useCmux, forSegment: 0)
        control.setLabel(state.keepTitle, forSegment: 1)
        control.selectedSegment = state.choosesCmux ? 0 : 1
        control.isEnabled = !state.pending
        note.stringValue = state.claimed ? OnboardingStrings.isDefaultBrowser : (state.note ?? "")
        note.isHidden = note.stringValue.isEmpty
    }
}
