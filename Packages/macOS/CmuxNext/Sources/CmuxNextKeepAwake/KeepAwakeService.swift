import CmuxNextBridge
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextSettings
public import CmuxNextWakeups
import Foundation

/// Holds off idle system sleep while an agent on this Mac works
/// (`sessions.keepAwake`), while phones can reach it (`phone.keepAwake`), or
/// while the Keep Mac Awake action is on. One activity
/// serves every reason, so the action and the setting never end each other's
/// hold. The display can still sleep, and closing the lid still sleeps the Mac.
public final class KeepAwakeService {
    public static let shared = KeepAwakeService()

    private(set) var policy = KeepAwakePolicy() {
        didSet { if policy != oldValue { apply() } }
    }
    private var activity: (any NSObjectProtocol)?
    /// The setting and agent-work observation; app lifetime, cancelled never.
    private var observation: ServiceObservation<Inputs?>?

    /// What the hold follows from the settings file and the agents: one value, so the hold never
    /// drops between the fields.
    nonisolated struct Inputs: Equatable, Sendable {
        var agents: SessionKeepAwakeSetting
        var phone: PhoneKeepAwakeSetting
        var agentsWorking: Bool
    }

    /// A service with nothing asking (the app's is ``shared``; tests make their own).
    public init() {}

    /// Whether the idle-sleep hold is taken now.
    public var isHolding: Bool { activity != nil }

    /// Follows the setting and local agent work on `mainWork`. Call once the settings
    /// controller exists; a second call does nothing. The power source comes
    /// from the App (``setOnBattery(_:)``).
    public func start(settings: SettingsController, store: DaemonStore, on mainWork: MainWorkScheduler) {
        follow(on: mainWork) {
            // The defaults before the first load are not the person's choice: nothing applies until it.
            guard settings.loadCount >= 1 else { return nil }
            let sessions = settings.snapshot.sessions
            return Inputs(agents: sessions.keepAwake, phone: sessions.phoneKeepAwake,
                          agentsWorking: KeepAwakeService.agentsWorking(store))
        }
    }

    /// Follows `read` (nil: not known yet). `background`: the hold shows nothing on screen, and a
    /// person's settings edit still applies in their turn (ServiceObservation's person cause).
    func follow(on mainWork: MainWorkScheduler, read: @escaping @MainActor () -> Inputs?) {
        guard observation == nil else { return }
        observation = ServiceObservation(.background, owner: "KeepAwakeService.inputs", on: mainWork, read: read) { [weak self] inputs in
            guard let self, let inputs else { return }
            var next = policy
            (next.agents, next.phone, next.agentsWorking) = (inputs.agents, inputs.phone, inputs.agentsWorking)
            policy = next
        }
    }

    /// The Mac runs on battery now (the App's energy monitor, at launch and on each change).
    public func setOnBattery(_ onBattery: Bool) {
        policy.onBattery = onBattery
    }

    /// Phones can reach this Mac now (`MobileHostService.isServing`).
    public func setPhoneServing(_ serving: Bool) {
        policy.phoneServing = serving
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

    private func apply() {
        if policy.holds, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "cmux keeps this Mac awake")
        } else if !policy.holds, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
    }
}
