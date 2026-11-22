import AppKit
import CmuxNextDesign

/// Two full-width radio rows, "Use cmux" and "Keep Safari". Choosing cmux
/// asks macOS at once; keeping the current browser changes nothing.
struct ChoiceRowsBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.choice"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Two Rows"
    static let summary = "Leading title, two radio rows (Use cmux / Keep current), opaque."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        var style = OnboardingScaffold.Style()
        style.margin = 48
        style.bodyGap = 32
        return OnboardingScaffold.make(title: OnboardingStrings.browserTitle, subtitle: OnboardingStrings.browserSubtitle,
                                       body: ChoiceRowsBrowserBody(model: context.model.defaults), context: context, style: style)
    }
}

final class ChoiceRowsBrowserBody: BrowserClaimView {
    private let cmuxRow = BrowserChoiceRow()
    private let keepRow = BrowserChoiceRow()
    private let note = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)

    override init(model: DefaultAppsStepModel) {
        super.init(model: model)
        cmuxRow.radio.target = self
        cmuxRow.radio.action = #selector(chooseCmux)
        keepRow.radio.target = self
        keepRow.radio.action = #selector(chooseKeep)
        let stack = NSStackView(views: [cmuxRow, keepRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: keepRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            cmuxRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keepRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
        ])
        startRendering()
    }

    @objc private func chooseCmux() {
        if model.isClaimed(.webBrowser) { apply(BrowserClaimState(model)) } else { requestClaim() }
    }

    /// Keeping is the state already; re-render puts the radios back.
    @objc private func chooseKeep() { apply(BrowserClaimState(model)) }

    override func apply(_ state: BrowserClaimState) {
        cmuxRow.set(title: BrowserVariantStrings.useCmux, on: state.choosesCmux, enabled: !state.pending)
        // macOS owns switching back: a click on Keep after the claim snaps back.
        keepRow.set(title: state.keepTitle, on: !state.choosesCmux, enabled: !state.pending)
        note.stringValue = state.note ?? ""
        note.isHidden = state.note == nil
    }
}

/// A 44 pt rounded row holding one radio; the whole row takes the click.
final class BrowserChoiceRow: ThemedView {
    let radio: NSButton = {
        let radio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
        radio.translatesAutoresizingMaskIntoConstraints = false
        radio.contentTintColor = Palette.textPrimary
        radio.bezelColor = Palette.textPrimary
        return radio
    }()
    private var on = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 10
        fill = { [weak self] in (self?.on ?? false) ? Palette.selectionFill : Palette.hoverFill }
        addSubview(radio)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            radio.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            radio.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            radio.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(title: String, on: Bool, enabled: Bool) {
        self.on = on
        radio.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: OnboardingMetrics.bodyFont, .foregroundColor: Palette.textPrimary,
        ])
        radio.state = on ? .on : .off
        radio.isEnabled = enabled
        applyColors()
    }

    @objc private func rowClicked() {
        guard radio.isEnabled, radio.state == .off else { return }
        radio.performClick(nil)
    }
}
