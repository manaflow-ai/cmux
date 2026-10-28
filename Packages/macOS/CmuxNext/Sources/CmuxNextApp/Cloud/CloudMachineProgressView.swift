import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextIcons
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
    private let titleLabel = ChromeLabel(labelWithString: "")
    private let elapsedLabel = ChromeLabel(labelWithString: "")
    private let stepsStack = NSStackView()
    private var stepRows: [(icon: NSImageView, label: ChromeLabel)] = []
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let typingLabel = ChromeLabel(wrappingLabelWithString: "")
    private let retryButton = ThemedDefaultButton()
    private let copyButton = ThemedBezelButton()
    private let dismissButton = ThemedBezelButton()
    private let buttons = NSStackView()
    /// The view's own visibility: visible while it is in a window and neither it nor an ancestor is hidden.
    private let node: VisibilityNode
    /// Renders the creation's stage while the view shows (R-obs: a view apply, held while hidden).
    private var observation: VisibleObservation<ProgressFacts>?
    /// The elapsed line's once-a-second deadline, armed only while the view shows.
    private let ticker: MainDeadline
    private var visibility: VisibilitySubscription?
    private let clock: ContinuousClock

    /// What the stage rows, the title and the detail show.
    private struct ProgressFacts: Equatable {
        var stage: CloudMachineStage
        var title: String?
        var workspaceID: String?
    }

    /// - Parameters:
    ///   - parent: The visibility node of the window that shows it.
    ///   - mainWork: The app's main-thread scheduler.
    ///   - deadlines: The app's one deadline scheduler.
    init(creation: CloudMachineCreation, actions: Actions, parent: VisibilityNode, mainWork: MainWorkScheduler,
         deadlines: MainDeadlineScheduler, clock: ContinuousClock = ContinuousClock()) {
        self.creation = creation
        self.actions = actions
        self.clock = clock
        node = VisibilityNode("cloud-creation", own: .hidden, parent: parent)
        ticker = MainDeadline(owner: "cloud.creation.elapsed", workClass: .visible, scheduler: deadlines)
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
            let label = ChromeLabel(labelWithString: CloudStrings.stage(step))
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
        detailLabel.focusRingType = .none
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
        retryButton.keyHint = .return
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
        // The first render is the observation's first apply, in this turn.
        observation = VisibleObservation(node, owner: "cloud.creation.progress", on: mainWork) {
            ProgressFacts(stage: creation.stage, title: creation.machineTitle, workspaceID: creation.workspaceID)
        } apply: { [weak self] _ in
            self?.render()
        }
        visibility = node.subscribe(owner: "cloud.creation.elapsed") { [weak self] state in
            guard let self else { return }
            if state.isVisible { startTicking() } else { ticker.cancel() }
        }
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

    /// In a window and not hidden itself: the node follows; the window's node covers the rest.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        node.set(window != nil && !isHidden ? .visible : .hidden)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        node.deferAppearance(owner: "CloudMachineProgressView") { [weak self] in
            self?.applyColors()
            self?.render()
        }
    }

    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            elapsedLabel.textColor = Palette.textTertiary
            detailLabel.textColor = Palette.textSecondary
            typingLabel.textColor = Palette.textTertiary
        }
    }

    // R-hide: hiding forwards to the node (a parked workspace stays in its window); its flip stops the ticker.
    override func viewDidHide() {
        super.viewDidHide()
        node.set(.hidden)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        node.set(window != nil ? .visible : .hidden)
    }

    private func startTicking() {
        if !creation.stage.isFinished, !ticker.isScheduled { tick() }
    }

    /// The elapsed line, once a second while the creation runs and the view shows.
    private func tick() {
        renderElapsed()
        guard node.isVisible, !creation.stage.isFinished else { return }
        ticker.schedule(after: .seconds(1)) { [weak self] in self?.tick() }
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
                let (icon, tint): (IconName, NSColor) =
                    if stage.failure != nil, index == current { (.statusError, Palette.danger) }
                    else if index < current || stage == .ready { (.statusComplete, Palette.success) }
                    else if index == current { (.statusInprogress, Palette.accent) }
                    else { (.stateIdle, Palette.textTertiary) }
                row.icon.image = NSImage.icon(icon, size: 16)
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
        // Paused is not a failure: one click on Resume starts the machine.
        buttons.isHidden = stage.failure == nil && !stage.isPaused
        copyButton.isHidden = stage.isPaused
        retryButton.title = stage.isPaused ? CloudStrings.resume : CloudStrings.retry
        typingLabel.isHidden = stage.failure != nil || stage.isPaused
        renderElapsed()
        if stage.isFinished { ticker.cancel() } else if node.isVisible, !ticker.isScheduled { tick() }
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
    var primaryButtonTitle: String { retryButton.title }
    var showsButtons: Bool { !buttons.isHidden }
}
