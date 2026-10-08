import AppKit
import CmuxNextDesign

/// Progress lives in a top bar of four short segments; the footer drops
/// its counter. Centered title, sentence and one glass button.
struct TopBarBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.topBar"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Top Bar Steps"
    static let summary = "Step segments in a top bar, centered title and button, footer without counter."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let steps = BrowserStepSegments(index: context.index, count: context.count)
        let title = OnboardingLabel.make(OnboardingStrings.browserTitle, font: .systemFont(ofSize: 22, weight: .semibold), lines: 2)
        let sentence = OnboardingLabel.make(OnboardingStrings.browserSubtitle, color: Palette.textSecondary, lines: 2)
        title.alignment = .center
        sentence.alignment = .center
        let body = TopBarBrowserBody(model: context.model.defaults)
        for view in [steps, title, sentence, body] as [NSView] { root.addSubview(view) }
        let footer = OnboardingFooter(context: context, showsCounter: false).pinBrowserFooter(in: root, margin: 40)
        NSLayoutConstraint.activate([
            // Level with the close button.
            steps.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            steps.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 112),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -128),
            sentence.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            sentence.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            sentence.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -128),
            body.topAnchor.constraint(equalTo: sentence.bottomAnchor, constant: 32),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 64),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -64),
            body.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
        ])
        return root
    }
}

final class TopBarBrowserBody: BrowserClaimView {
    private let status = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)
    private var button: NSButton!

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        button = OnboardingControl.button(OnboardingStrings.makeDefaultBrowser, prominent: true, target: self, action: #selector(requestClaim))
        status.alignment = .center
        let stack = NSStackView(views: [button, status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
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

/// Four 24x4 capsules: done and current steps in the primary text color,
/// later ones in the separator color.
final class BrowserStepSegments: NSStackView {
    init(index: Int, count: Int) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        for step in 0..<count {
            let segment = ThemedView()
            segment.cornerRadius = 2
            segment.fill = step <= index ? { Palette.textPrimary } : { Palette.separator }
            NSLayoutConstraint.activate([
                segment.widthAnchor.constraint(equalToConstant: 24), segment.heightAnchor.constraint(equalToConstant: 4),
            ])
            addArrangedSubview(segment)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(OnboardingStrings.stepCounter(index + 1, count))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
