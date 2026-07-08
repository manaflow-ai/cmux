import Combine
import CmuxSettings
import Foundation
import IOKit.pwr_mgt

@MainActor
final class PreventSleepManager {
    // Process-wide power assertion owner. This mirrors other app-lifecycle
    // singletons and keeps the assertion independent of any one window.
    static let shared = PreventSleepManager()

    private let assertion = PowerAssertionHolder(
        type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        reason: "cmux keep-awake: agents running or mobile client connected"
    )
    private var isStarted = false
    private var defaultsObserver: NSObjectProtocol?
    private var mobileObserver: NSObjectProtocol?
    private var mainWindowContextsObserver: NSObjectProtocol?
    private var agentObservationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var tabManagerCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    /// Running-agent count per observed workspace model, maintained
    /// incrementally by ``agentModelDidChange(_:)`` so per-agent runtime
    /// events never trigger an app-wide workspace sweep. Fully rebuilt only
    /// on topology/settings syncs.
    private var runningAgentCountsByModel: [ObjectIdentifier: Int] = [:]

    private init() {}

    var isHoldingAssertion: Bool { assertion.isHeld }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installDefaultsObserver()
        installMobileObserver()
        installMainWindowContextsObserver()
        syncNow()
    }

    func stop() {
        guard isStarted else {
            assertion.release()
            return
        }
        isStarted = false
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        if let mobileObserver {
            NotificationCenter.default.removeObserver(mobileObserver)
            self.mobileObserver = nil
        }
        if let mainWindowContextsObserver {
            NotificationCenter.default.removeObserver(mainWindowContextsObserver)
            self.mainWindowContextsObserver = nil
        }
        cancelAgentObservation()
        assertion.release()
    }

    func syncNow() {
        sync(tabsOverride: nil)
    }

    /// Topology/settings sync: (re)builds the observer set and the per-model
    /// count table, then reconciles. Runs on defaults changes, mobile status
    /// changes, window-context changes, and tab-list changes — never on
    /// per-agent runtime events (those go through ``agentModelDidChange(_:)``).
    private func sync(tabsOverride: (tabManager: TabManager, tabs: [Workspace])?) {
        // Agent observation (per-workspace change streams, tab list
        // subscriptions, and per-model counting) stays fully off unless the
        // default-off agents setting is on, so non-opted-in users pay no
        // per-agent-event or per-defaults-change fanout.
        if settingValue(SettingCatalog().power.preventSleepWhileAgentsRunning) {
            refreshTabManagerObservers()
            rebuildAgentObservation(for: openWorkspaces(tabsOverride: tabsOverride))
        } else {
            cancelAgentObservation()
        }
        reconcileAssertion()
    }

    /// Constant-work reconcile: sums the maintained per-model counts and reads
    /// the lean authenticated-connection count (never `statusSnapshot()`, whose
    /// route resolution enumerates network interfaces). The mobile gate uses
    /// authenticated connections only: raw accepted TCP sessions can be held
    /// open by unauthenticated peers via the auth-exempt status verb.
    private func reconcileAssertion() {
        let power = SettingCatalog().power
        let desired = preventSleepDesired(
            agentsSettingEnabled: settingValue(power.preventSleepWhileAgentsRunning),
            mobileSettingEnabled: settingValue(power.preventSleepWhileMobileConnected),
            runningAgentCount: runningAgentCountsByModel.values.reduce(0, +),
            mobileConnectionCount: MobileHostService.shared.authenticatedConnectionCount
        )
        if desired {
            assertion.acquire()
        } else {
            assertion.release()
        }
    }

    /// `tabsPublisher` emits during willSet — before `tabManager.tabs` storage
    /// commits — so reconciliation must take the emitting manager's NEW list
    /// from the override and never re-read its not-yet-updated `tabs`.
    /// Otherwise closing the last agent workspace would reconcile against the
    /// old list and leave the sleep assertion held.
    private func openWorkspaces(tabsOverride: (tabManager: TabManager, tabs: [Workspace])?) -> [Workspace] {
        guard let app = AppDelegate.shared else { return tabsOverride?.tabs ?? [] }
        return app.mainWindowContexts.values.flatMap { context -> [Workspace] in
            if let tabsOverride, context.tabManager === tabsOverride.tabManager {
                return tabsOverride.tabs
            }
            return context.tabManager.tabs
        }
    }

    private func installDefaultsObserver() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncNow()
            }
        }
    }

    private func installMobileObserver() {
        guard mobileObserver == nil else { return }
        mobileObserver = NotificationCenter.default.addObserver(
            forName: .mobileHostStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Mobile connection/route events cannot change workspace
                // topology or agent observation, so reconcile leanly instead
                // of widening every mobile status change into an app-wide
                // observer rebuild.
                self?.reconcileAssertion()
            }
        }
    }

    private func installMainWindowContextsObserver() {
        guard mainWindowContextsObserver == nil else { return }
        mainWindowContextsObserver = NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncNow()
            }
        }
    }

    private func refreshTabManagerObservers() {
        guard let app = AppDelegate.shared else { return }
        let tabManagers = app.mainWindowContexts.values.map(\.tabManager)
        let currentIDs = Set(tabManagers.map(ObjectIdentifier.init))

        for id in tabManagerCancellables.keys where !currentIDs.contains(id) {
            tabManagerCancellables[id]?.cancel()
            tabManagerCancellables[id] = nil
        }

        for tabManager in tabManagers {
            let id = ObjectIdentifier(tabManager)
            guard tabManagerCancellables[id] == nil else { continue }
            tabManagerCancellables[id] = tabManager.tabsPublisher
                .dropFirst()
                .sink { [weak self, weak tabManager] tabs in
                    guard let tabManager else { return }
                    self?.sync(tabsOverride: (tabManager, tabs))
                }
        }
    }

    private func rebuildAgentObservation(for workspaces: [Workspace]) {
        let models = workspaces.map(\.sidebarAgentRuntimeObservation)
        let currentIDs = Set(models.map(ObjectIdentifier.init))

        for id in agentObservationTasks.keys where !currentIDs.contains(id) {
            agentObservationTasks[id]?.cancel()
            agentObservationTasks[id] = nil
            runningAgentCountsByModel[id] = nil
        }

        for model in models {
            let id = ObjectIdentifier(model)
            // Topology syncs are rare, so refresh every count here and the
            // aggregate can never drift from missed events.
            runningAgentCountsByModel[id] = Self.runningAgentCount(in: model.agentPIDs)
            guard agentObservationTasks[id] == nil else { continue }
            agentObservationTasks[id] = Task { @MainActor [weak self, weak model] in
                guard let model else { return }
                for await _ in model.changes() {
                    if Task.isCancelled { break }
                    self?.agentModelDidChange(model)
                }
            }
        }
    }

    /// Scoped handler for one workspace's agent runtime events. `changes()`
    /// fires for panel/lifecycle map churn too, so recompute only the emitting
    /// model's count and reconcile only when that count actually moved —
    /// an app-wide sweep here would multiply hot agent events into main-actor
    /// scans of every workspace.
    private func agentModelDidChange(_ model: WorkspaceSidebarAgentRuntimeObservationModel) {
        let id = ObjectIdentifier(model)
        guard agentObservationTasks[id] != nil else { return }
        let newCount = Self.runningAgentCount(in: model.agentPIDs)
        guard runningAgentCountsByModel[id] != newCount else { return }
        runningAgentCountsByModel[id] = newCount
        reconcileAssertion()
    }

    private static func runningAgentCount(in agentPIDs: [String: pid_t]) -> Int {
        var total = 0
        for pid in agentPIDs.values where pid > 0 {
            total += 1
        }
        return total
    }

    private func cancelAgentObservation() {
        for task in agentObservationTasks.values {
            task.cancel()
        }
        agentObservationTasks.removeAll()
        for cancellable in tabManagerCancellables.values {
            cancellable.cancel()
        }
        tabManagerCancellables.removeAll()
        runningAgentCountsByModel.removeAll()
    }

    private func settingValue(_ key: DefaultsKey<Bool>) -> Bool {
        UserDefaults.standard.object(forKey: key.userDefaultsKey) as? Bool ?? key.defaultValue
    }
}
