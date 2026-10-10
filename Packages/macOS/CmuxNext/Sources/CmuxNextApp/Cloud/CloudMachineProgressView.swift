import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// The content of a window that shows a New Cloud Workspace before its
/// terminal exists (cx-lu8f): each stage with its state, the stage the
/// machine is in now, the time since the click, and what happens next. A
/// failure shows its reason with Retry, Copy Error and Dismiss. Stages come
/// from `CloudMachineCreation.stage` (real events); the elapsed line is the
/// only thing a clock moves, once a second while the view is in a window.
/// Typing has nowhere to go yet: the view takes the keys and says so.
final class CloudMachineProgressView: NSView {
    struct Actions {
        var retry: (CloudMachineCreation) -> Void
        var dismiss: (CloudMachineCreation) -> Void
    }

    let creation: CloudMachineCreation
    private let actions: Actions
    private let titleLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let stepsStack = NSStackView()
    private var stepRows: [(icon: NSImageView, label: NSTextField)] = []
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let typingLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton()
    private let copyButton = NSButton()
    private let dismissButton = NSButton()
    private let buttons = NSStackView()
    private var observation: Task<Void, Never>?
    private let ticker: DemandTimer
    private let clock: ContinuousClock

    init(creation: CloudMachineCreation, actions: Actions, clock: ContinuousClock = ContinuousClock()) {
        self.creation = creation
        self.actions = actions
        self.clock = clock
        ticker = DemandTimer(owner: "cloud.creation.elapsed", clock: clock)
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.font = Typography.title
        titleLabel.alignment = .center
        elapsedLabel.font = Typography.shortcut
        elapsedLabel.alignment = .center
        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.spacing = Metrics.space2
        for step in CloudMachineStage.steps {
            let icon = NSImageView()
            icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            let label = NSTextField(labelWithString: CloudStrings.stage(step))
            label.font = Typography.body
            let row = NSStackView(views: [icon, label])
            row.orientation = .horizontal
            row.spacing = Metrics.space2
            stepsStack.addArrangedSubview(row)
            stepRows.append((icon, label))
        }
        detailLabel.font = Typography.body
        detailLabel.alignment = .center
        detailLabel.isSelectable = true
        detailLabel.maximumNumberOfLines = 8
        typingLabel.font = Typography.caption
        typingLabel.alignment = .center
        typingLabel.stringValue = CloudStrings.progressTypingNote
        for (button, title, action) in [(retryButton, CloudStrings.retry, #selector(retryPressed)),
                                        (copyButton, CloudStrings.copyError, #selector(copyPressed)),
                                        (dismissButton, CloudStrings.dismiss, #selector(dismissPressed))] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            buttons.addArrangedSubview(button)
        }
        retryButton.keyEquivalent = "\r"
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space2
        let stack = NSStackView(views: [titleLabel, elapsedLabel, stepsStack, detailLabel, buttons, typingLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.space4
        stack.setCustomSpacing(Metrics.space1, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.space4),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.cloud.creation.progress")
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// Keys typed before the terminal exists are not sent anywhere: the
    /// note under the steps says so (it is always shown), and no beep.
    override func keyDown(with event: NSEvent) {
        guard creation.stage.failure == nil else { return super.keyDown(with: event) }
        performWithTheme { typingLabel.textColor = Palette.textPrimary }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        observation?.cancel()
        ticker.cancel()
        guard window != nil else { return }
        let creation = creation
        observation = Task { [weak self] in
            for await _ in ObservationStream({ (creation.stage, creation.machineTitle, creation.workspaceID) }) {
                self?.render()
            }
        }
        tick()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        render()
    }

    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            elapsedLabel.textColor = Palette.textTertiary
            detailLabel.textColor = Palette.textSecondary
            typingLabel.textColor = Palette.textTertiary
        }
    }

    /// The elapsed line, once a second while the creation runs.
    private func tick() {
        renderElapsed()
        guard window != nil, !creation.stage.isFinished else { return }
        ticker.schedule(after: .seconds(1)) { @MainActor [weak self] in self?.tick() }
    }

    private func renderElapsed() {
        elapsedLabel.stringValue = CloudStrings.elapsed(creation.elapsed(now: clock.now))
    }

    private func render() {
        let stage = creation.stage
        titleLabel.stringValue = creation.machineTitle.map(CloudStrings.progressTitle(machine:)) ?? CloudStrings.newCloudWorkspaceTitle
        let current = stage.stepIndex ?? lastReached
        performWithTheme {
            for (index, row) in stepRows.enumerated() {
                let (symbol, tint): (String, NSColor) =
                    if stage.failure != nil, index == current { ("xmark.octagon.fill", Palette.danger) }
                    else if index < current || stage == .ready { ("checkmark.circle.fill", Palette.success) }
                    else if index == current { ("circle.dotted.circle", Palette.accent) }
                    else { ("circle", Palette.textTertiary) }
                row.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                row.icon.contentTintColor = tint
                row.label.textColor = index <= current ? Palette.textPrimary : Palette.textTertiary
                row.label.font = index == current ? Typography.bodyEmphasized : Typography.body
            }
        }
        if let failure = stage.failure {
            detailLabel.stringValue = CloudStrings.progressFailed(failure)
        } else {
            lastReached = current
            detailLabel.stringValue = CloudStrings.stageNext(stage)
        }
        buttons.isHidden = stage.failure == nil
        typingLabel.isHidden = stage.failure != nil
        renderElapsed()
        if stage.isFinished { ticker.cancel() } else if window != nil, !ticker.isScheduled { tick() }
        setAccessibilityLabel([titleLabel.stringValue, CloudStrings.stage(stage), detailLabel.stringValue].joined(separator: ". "))
    }

    /// The step a failure stopped at: the last one reached before it.
    private var lastReached = 0

    @objc private func retryPressed() { actions.retry(creation) }
    @objc private func copyPressed() { if let failure = creation.stage.failure { CloudPresenter.copy(failure) } }
    @objc private func dismissPressed() { actions.dismiss(creation) }

    // MARK: Tests

    var titleText: String { titleLabel.stringValue }
    var detailText: String { detailLabel.stringValue }
    var showsFailureButtons: Bool { !buttons.isHidden }
}
