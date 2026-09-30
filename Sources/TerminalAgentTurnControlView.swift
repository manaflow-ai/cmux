import AppKit
import CmuxSettings

/// Stop button shown in the terminal's bottom-trailing corner while a
/// supported agent is working on a turn in this pane (`agentActions.turnControl`).
///
/// The view covers the terminal but only the button takes clicks; everywhere
/// else hit-testing falls through to the terminal.
final class TerminalAgentTurnControlView: NSView {
    /// Called with the running agent when the user clicks Stop.
    var onInterrupt: ((AgentTurnInterruptTarget) -> Void)?

    private let backdrop = NSVisualEffectView(frame: .zero)
    private let stopButton = TerminalAgentTurnControlButton(frame: .zero)
    private let clock: any Clock<Duration>
    private(set) var target: AgentTurnInterruptTarget?
    /// How long Stop stays disabled after a click.
    static let stopHoldInterval: Duration = .milliseconds(1_500)
    private var stopHoldGeneration: UInt64 = 0
    private var stopHoldTask: Task<Void, Never>?
    private var isEnabledBySetting = false
    /// Registered only while an agent is running, so toggling the setting
    /// mid-turn applies at once without every idle terminal observing defaults.
    private var settingsObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let hit = super.hitTest(point) else { return nil }
        return hit === stopButton || hit.isDescendant(of: stopButton) ? hit : nil
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, clock: ContinuousClock())
    }

    init(frame frameRect: NSRect, clock: any Clock<Duration>) {
        self.clock = clock
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

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.isBordered = false
        stopButton.imagePosition = .imageLeading
        stopButton.imageHugsTitle = true
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stopButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        stopButton.font = .systemFont(ofSize: 11, weight: .medium)
        stopButton.title = String(localized: "terminal.agentTurnControl.stop", defaultValue: "Stop")
        stopButton.contentTintColor = .labelColor
        stopButton.target = self
        stopButton.action = #selector(handleStop)

        addSubview(backdrop)
        backdrop.addSubview(stopButton)
        NSLayoutConstraint.activate([
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            backdrop.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            stopButton.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
            stopButton.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            stopButton.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 3),
            stopButton.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        stopHoldTask?.cancel()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    /// Applies the agent currently running in this pane, or `nil` when none is.
    func setRunningTarget(_ target: AgentTurnInterruptTarget?) {
        if target != nil, self.target == nil {
            reloadSetting()
        }
        observeSetting(target != nil)
        if target != self.target {
            stopHoldGeneration &+= 1
            stopHoldTask?.cancel()
            stopHoldTask = nil
            stopButton.isEnabled = true
        }
        self.target = target
        render()
    }

    @discardableResult
    private func reloadSetting() -> Bool {
        let enabled = AgentActionsCatalogSection().turnControl.value(in: .standard)
        guard enabled != isEnabledBySetting else { return false }
        isEnabledBySetting = enabled
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
                }
            }
        } else if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
    }

    private func render() {
        guard let target, isEnabledBySetting else {
            isHidden = true
            return
        }
        let help = String(
            localized: "terminal.agentTurnControl.stop.help",
            defaultValue: "Interrupt \(target.displayName) (Esc)"
        )
        stopButton.toolTip = help
        stopButton.setAccessibilityLabel(help)
        isHidden = false
    }

    @objc private func handleStop() {
        guard let target, isEnabledBySetting, stopButton.isEnabled else { return }
        // One Escape per click: a second Escape at Claude's idle prompt opens
        // its rewind menu. Hold the button until the lifecycle catches up.
        stopButton.isEnabled = false
        let generation = stopHoldGeneration &+ 1
        stopHoldGeneration = generation
        stopHoldTask?.cancel()
        let clock = clock
        stopHoldTask = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: Self.stopHoldInterval)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.stopHoldGeneration == generation else { return }
            self.stopButton.isEnabled = true
        }
        onInterrupt?(target)
    }
}
