import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// Holds off idle system sleep while an agent on this Mac works
/// (`sessions.keepAwake`), while a long terminal command runs when
/// `sessions.keepAwakeForCommands` is on, while phones can reach it (`phone.keepAwake`), or
/// while the Keep Mac Awake action is on. One activity
/// serves every reason, so the action and the setting never end each other's
/// hold. The display can still sleep, and closing the lid still sleeps the Mac.
public final class KeepAwakeService {
    public static let shared = KeepAwakeService()

    private(set) var policy = KeepAwakePolicy() {
        didSet { if policy != oldValue { apply() } }
    }
    private var activity: (any NSObjectProtocol)?
    private let power = PowerSourceMonitor()
    /// The setting and agent-work observation; app lifetime, cancelled never.
    private var observation: Task<Void, Never>?
    /// The running commands last seen, planned again when `recheck` fires.
    private var commands = KeepAwakeCommands()
    /// One deadline at a time: a young command comes of age or a counting one goes quiet
    /// (the plan's `recheck_ms`); cancelled when no command is young or counting.
    private let recheck = DemandTimer(owner: "keep-awake.commands")
    /// The menu bar item, told what holds the Mac awake (its Keeping Mac awake line).
    private weak var menuBar: MenuBarExtra?

    /// Follows the setting, local agent work and the power source, and tells `menuBar` what holds.
    /// Call once the settings controller exists; a second call does nothing.
    public func start(settings: SettingsController, store: DaemonStore, menuBar: MenuBarExtra? = nil) {
        guard observation == nil else { return }
        self.menuBar = menuBar
        power.onChange = { [weak self] onBattery in self?.policy.onBattery = onBattery }
        policy.onBattery = power.start()
        observation = Task { [weak self] in
            await settings.waitForLoad(atLeast: 1)
            for await (sessions, working, commands) in ObservationStream({
                let sessions = settings.snapshot.sessions
                // The command facts are read only while the setting is on, so off, no tab wakes this.
                let commands = sessions.keepAwakeForCommands ? KeepAwakeCommands.of(store) : KeepAwakeCommands()
                return (sessions, KeepAwakeService.agentsWorking(store), commands)
            }) {
                guard let self else { return }
                self.commands = commands
                // One write, so the hold never drops between the fields.
                var next = self.policy
                (next.agents, next.phone, next.agentsWorking) = (sessions.keepAwake, sessions.phoneKeepAwake, working)
                next.commands = sessions.keepAwakeForCommands
                next.commandsRunning = self.planCommands()
                self.policy = next
            }
        }
    }

    /// Phones can reach this Mac now (`MobileHostService.isServing`).
    public func setPhoneServing(_ serving: Bool) {
        policy.phoneServing = serving
    }

    /// NEXT phones can reach this Mac; turning either host off preserves the other hold.
    public func setIPhoneServing(_ serving: Bool) {
        policy.iPhoneServing = serving
    }

    /// The Keep Mac Awake action: a second run turns it off.
    public func toggleManual() {
        policy.manual.toggle()
    }

    /// Some local agent runs a turn: an acpmux session (with or without a tab
    /// showing it) or a tab's agent hooks or OSC 7501 `working` record.
    /// Other machines' agents run there and keep that machine awake.
    static func agentsWorking(_ store: DaemonStore) -> Bool {
        if AgentTurnStateStore.shared.hasWorkingSession { return true }
        let tabs = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        return StatusMapping.shared.isWorking(tabs: tabs)
    }

    /// The commands that count now, from the Rust rule, and the one deadline it asks for.
    private func planCommands() -> Int {
        let plan = commands.plan()
        if let after = plan.recheckMs {
            recheck.schedule(after: .milliseconds(after)) { @MainActor [weak self] in
                guard let self else { return }
                self.policy.commandsRunning = self.planCommands()
            }
        } else {
            recheck.cancel()
        }
        return plan.running
    }

    private func apply() {
        if policy.holds, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "cmux keeps this Mac awake")
        } else if !policy.holds, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
        // The menu bar's line: what holds, nil once nothing does.
        menuBar?.keepingAwake = activity == nil ? nil
            : MenuBarMenuState.KeepingAwake(commands: policy.commands ? policy.commandsRunning : 0, setting: policy.setting)
    }
}
