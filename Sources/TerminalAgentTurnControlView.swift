import AppKit
import CmuxSettings

/// Agent action pill in the terminal's bottom-trailing corner while a
/// supported agent is working on a turn in this pane: Stop
/// (`agentActions.turnControl`) and, while Claude Code has prompts queued,
/// Edit Queued (`agentActions.promptEditing`).
///
/// The view covers the terminal but only the button takes clicks; everywhere
/// else hit-testing falls through to the terminal.
final class TerminalAgentTurnControlView: NSView {
    /// Called with the running agent when the user clicks Stop.
    var onInterrupt: ((AgentTurnInterruptTarget) -> Void)?
    /// Called when the user clicks Edit Queued.
    var onEditQueued: (() -> Void)?
    /// Called with the Turns button when the user clicks it.
    var onShowTurns: ((NSView) -> Void)?
    /// Called when either agent action setting changes while an agent runs.
    var onSettingsChange: (() -> Void)?

    private let backdrop = NSVisualEffectView(frame: .zero)
    private let stopButton = TerminalAgentTurnControlButton(frame: .zero)
    private let editQueuedButton = TerminalAgentTurnControlButton(frame: .zero)
    private let turnsButton = TerminalAgentTurnControlButton(frame: .zero)
    private let buttonStack = NSStackView(frame: .zero)
    private(set) var target: AgentTurnInterruptTarget?
    /// The supported agent with a session in this pane, running or not.
    private(set) var presentAgent: AgentTurnInterruptTarget?
    /// How long Stop stays disabled after a click.
    static let stopHoldInterval: TimeInterval = 1.5
    private var stopHoldGeneration: UInt64 = 0
    private var editQueuedHoldGeneration: UInt64 = 0
    private var isEnabledBySetting = false
    private(set) var isPromptEditingEnabled = false
    private(set) var queuedPromptCount = 0
    /// Registered only while an agent is running, so toggling the setting
    /// mid-turn applies at once without every idle terminal observing defaults.
    private var settingsObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let hit = super.hitTest(point) else { return nil }
        let isButton = [stopButton, editQueuedButton, turnsButton].contains { hit === $0 || hit.isDescendant(of: $0) }
        return isButton ? hit : nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        backdrop.alphaValue = 0.96

        configure(
            stopButton,
            symbol: "stop.fill",
            title: String(localized: "terminal.agentTurnControl.stop", defaultValue: "Stop"),
            action: #selector(handleStop)
        )
        configure(
            editQueuedButton,
            symbol: "arrow.up.message",
            title: String(localized: "terminal.agentTurnControl.editQueued", defaultValue: "Edit Queued"),
            action: #selector(handleEditQueued)
        )
        configure(
            turnsButton,
            symbol: "clock.arrow.circlepath",
            title: String(localized: "terminal.agentTurnControl.turns", defaultValue: "Turns"),
            action: #selector(handleShowTurns)
        )
        let turnsHelp = String(
            localized: "terminal.agentTurnControl.turns.help",
            defaultValue: "Show this session's prompts: edit one again or fork from it"
        )
        turnsButton.toolTip = turnsHelp
        turnsButton.setAccessibilityLabel(turnsHelp)
        let editQueuedHelp = String(
            localized: "terminal.agentTurnControl.editQueued.help",
            defaultValue: "Move queued prompts back into Claude's input (Up)"
        )
        editQueuedButton.toolTip = editQueuedHelp
        editQueuedButton.setAccessibilityLabel(editQueuedHelp)

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10
        buttonStack.addArrangedSubview(turnsButton)
        buttonStack.addArrangedSubview(editQueuedButton)
        buttonStack.addArrangedSubview(stopButton)

        addSubview(backdrop)
        backdrop.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            backdrop.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            buttonStack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
            buttonStack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            buttonStack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 3),
            buttonStack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func configure(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.title = title
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
    }

    /// Applies how many prompts Claude has queued in this pane.
    func setQueuedPromptCount(_ count: Int) {
        editQueuedHoldGeneration &+= 1
        editQueuedButton.isEnabled = true
        guard count != queuedPromptCount else { return }
        queuedPromptCount = count
        render()
    }

    /// Applies the agent currently running in this pane (`target`) and the
    /// agent with a session here at all (`present`), or `nil` for none.
    func setAgents(running target: AgentTurnInterruptTarget?, present: AgentTurnInterruptTarget?) {
        presentAgent = present ?? target
        setRunningTarget(target)
    }

    /// Applies the agent currently running in this pane, or `nil` when none is.
    func setRunningTarget(_ target: AgentTurnInterruptTarget?) {
        let isActive = target != nil || presentAgent != nil
        if isActive, settingsObserver == nil {
            reloadSetting()
        }
        observeSetting(isActive)
        if target != self.target {
            stopHoldGeneration &+= 1
            stopButton.isEnabled = true
        }
        self.target = target
        render()
    }

    @discardableResult
    private func reloadSetting() -> Bool {
        let settings = AgentActionsCatalogSection()
        let enabled = settings.turnControl.value(in: .standard)
        let promptEditing = settings.promptEditing.value(in: .standard)
        guard enabled != isEnabledBySetting || promptEditing != isPromptEditingEnabled else { return false }
        isEnabledBySetting = enabled
        isPromptEditingEnabled = promptEditing
        return true
    }

    private func observeSetting(_ observe: Bool) {
        if observe {
            guard settingsObserver == nil else { return }
            settingsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.reloadSetting() else { return }
                    self.render()
                    self.onSettingsChange?()
                }
            }
        } else if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
    }

    private func render() {
        let showsStop = target != nil && isEnabledBySetting
        let showsEditQueued = isPromptEditingEnabled && target == .claudeCode && queuedPromptCount > 0
        let showsTurns = isPromptEditingEnabled && presentAgent != nil
        stopButton.isHidden = !showsStop
        editQueuedButton.isHidden = !showsEditQueued
        turnsButton.isHidden = !showsTurns
        guard showsStop || showsEditQueued || showsTurns else {
            isHidden = true
            return
        }
        if let target {
            let help = String(
                localized: "terminal.agentTurnControl.stop.help",
                defaultValue: "Interrupt \(target.displayName) (Esc)"
            )
            stopButton.toolTip = help
            stopButton.setAccessibilityLabel(help)
        }
        isHidden = false
    }

    /// Clicks Stop the way the user would, for tests.
    func clickStopForTesting() {
        stopButton.performClick(nil)
    }

    /// Clicks Edit Queued the way the user would, for tests.
    func clickEditQueuedForTesting() {
        editQueuedButton.performClick(nil)
    }

    var isEditQueuedVisible: Bool { !isHidden && !editQueuedButton.isHidden }

    @objc private func handleStop() {
        guard let target, isEnabledBySetting, stopButton.isEnabled else { return }
        // One Escape per click: a second Escape at Claude's idle prompt opens
        // its rewind menu. Hold the button until the lifecycle catches up.
        stopButton.isEnabled = false
        let generation = stopHoldGeneration &+ 1
        stopHoldGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopHoldInterval) { [weak self] in
            guard let self, self.stopHoldGeneration == generation else { return }
            self.stopButton.isEnabled = true
        }
        onInterrupt?(target)
    }

    @objc private func handleShowTurns() {
        guard presentAgent != nil, isPromptEditingEnabled else { return }
        onShowTurns?(turnsButton)
    }

    /// Whether the Turns button is showing, for tests.
    var isTurnsVisible: Bool { !isHidden && !turnsButton.isHidden }

    @objc private func handleEditQueued() {
        guard target == .claudeCode, isPromptEditingEnabled, queuedPromptCount > 0,
              editQueuedButton.isEnabled else { return }
        // Hold until the transcript reports the queue, which hides the button
        // once Up pulled the prompts back. If Up only moved the cursor, the
        // count is unchanged and the button comes back.
        editQueuedButton.isEnabled = false
        let generation = editQueuedHoldGeneration &+ 1
        editQueuedHoldGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopHoldInterval) { [weak self] in
            guard let self, self.editQueuedHoldGeneration == generation else { return }
            self.editQueuedButton.isEnabled = true
        }
        onEditQueued?()
    }
}

private final class TerminalAgentTurnControlButton: NSButton {
    override var acceptsFirstResponder: Bool { false }

    /// Stop works on the first click even when the window isn't key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
