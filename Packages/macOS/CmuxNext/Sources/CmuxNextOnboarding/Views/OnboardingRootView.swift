import AppKit
import CmuxNextDesign

/// The window's content: a short title, one sentence, the step's control,
/// and a footer with "2 of 4", Skip and Continue. Lives on the window's one
/// Liquid Glass surface.
final class OnboardingRootView: NSView {
    private let model: OnboardingModel
    private let titleLabel = OnboardingLabel.make(font: OnboardingMetrics.titleFont)
    private let subtitle = OnboardingLabel.make(color: Palette.textSecondary, lines: 2)
    private let counter = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary)
    private let body = NSView()
    private var skip: NSButton!
    private var next: NSButton!
    private var shownStep: OnboardingModel.Step?
    private var stepView: NSView?
    private var loop: RenderLoop?

    init(model: OnboardingModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: OnboardingMetrics.windowSize))
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
        skip = OnboardingControl.plainButton(OnboardingStrings.skip, target: self, action: #selector(skipPressed))
        next = OnboardingControl.button(OnboardingStrings.continueButton, prominent: true, target: self, action: #selector(nextPressed))
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLabel, subtitle, body, counter, skip!, next!] as [NSView] { addSubview(view) }
        let margin = OnboardingMetrics.margin
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: OnboardingMetrics.titleTop),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -margin),
            subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -margin),
            body.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 28),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -OnboardingMetrics.footerHeight - 8),
            counter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            counter.centerYAnchor.constraint(equalTo: next.centerYAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin + 4),
            next.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin + 12),
            skip.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -20),
            skip.centerYAnchor.constraint(equalTo: next.centerYAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    @objc private func skipPressed() { model.skipStep() }
    @objc private func nextPressed() { model.next() }

    private func render() {
        let step = model.step
        counter.stringValue = OnboardingStrings.stepCounter(model.index + 1, model.steps.count)
        next.title = model.isLast ? OnboardingStrings.done : OnboardingStrings.continueButton
        guard step != shownStep else { return }
        shownStep = step
        titleLabel.stringValue = title(step)
        subtitle.stringValue = subtitleText(step)
        stepView?.removeFromSuperview()
        let view = makeStepView(step)
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor), view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.topAnchor.constraint(equalTo: body.topAnchor), view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        stepView = view
        StepTransition.reveal(view)
    }

    private func makeStepView(_ step: OnboardingModel.Step) -> NSView {
        switch step {
        case .defaultBrowser: DefaultBrowserStepView(model: model.defaults)
        case .importData: ImportStepView(model: model.importer)
        case .theme: ThemeStepView(model: model.theme)
        case .accounts: model.services.makeAccountsStepView() ?? NSView()
        }
    }

    private func title(_ step: OnboardingModel.Step) -> String {
        switch step {
        case .defaultBrowser: OnboardingStrings.browserTitle
        case .importData: OnboardingStrings.importTitle
        case .theme: OnboardingStrings.themeTitle
        case .accounts: OnboardingStrings.accountsTitle
        }
    }

    private func subtitleText(_ step: OnboardingModel.Step) -> String {
        switch step {
        case .defaultBrowser: OnboardingStrings.browserSubtitle
        case .importData: OnboardingStrings.importSubtitle
        case .theme: OnboardingStrings.themeSubtitle
        case .accounts: OnboardingStrings.accountsSubtitle
        }
    }
}
