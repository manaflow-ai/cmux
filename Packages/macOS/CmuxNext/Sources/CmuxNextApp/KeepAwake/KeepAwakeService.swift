import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSettings
import Foundation

/// Holds off idle system sleep while an agent on this Mac works
/// (`sessions.keepAwake`) or the Keep Mac Awake action is on. One activity
/// serves every reason, so the action and the setting never end each other's
/// hold. The display can still sleep, and closing the lid still sleeps the Mac.
final class KeepAwakeService {
    static let shared = KeepAwakeService()

    private(set) var policy = KeepAwakePolicy() {
        didSet { if policy != oldValue { apply() } }
    }
    private var activity: (any NSObjectProtocol)?
    private let power = PowerSourceMonitor()
    /// The setting and agent-work observation; app lifetime, cancelled never.
    private var observation: Task<Void, Never>?

    /// Follows the setting, local agent work and the power source. Call once
    /// the settings controller exists; a second call does nothing.
    func start(settings: SettingsController, daemon: DaemonService) {
        guard observation == nil else { return }
        power.onChange = { [weak self] onBattery in self?.policy.onBattery = onBattery }
        policy.onBattery = power.start()
        observation = Task { [weak self] in
            await settings.waitForLoad(atLeast: 1)
            for await (choice, working) in ObservationStream({
                (settings.snapshot.sessions.keepAwake, KeepAwakeService.agentsWorking(daemon))
            }) {
                self?.policy.agents = choice
                self?.policy.agentsWorking = working
            }
        }
    }

    /// The Keep Mac Awake action: a second run turns it off.
    func toggleManual() {
        policy.manual.toggle()
    }

    /// Some local agent runs a turn: an acpmux session (with or without a tab
    /// showing it) or a tab's agent hooks or OSC 7501 `working` record.
    /// Other machines' agents run there and keep that machine awake.
    static func agentsWorking(_ daemon: DaemonService) -> Bool {
        if AgentTurnStateStore.shared.hasWorkingSession { return true }
        let tabs = daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        return StatusMapping.shared.isWorking(tabs: tabs)
    }

    private func apply() {
        if policy.holds, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "cmux keeps this Mac awake")
        } else if !policy.holds, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
    }
}
