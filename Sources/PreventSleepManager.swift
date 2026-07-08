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

    private func sync(tabsOverride: (tabManager: TabManager, tabs: [Workspace])?) {
        let power = SettingCatalog().power
        let agentsSettingEnabled = settingValue(power.preventSleepWhileAgentsRunning)
        let mobileSettingEnabled = settingValue(power.preventSleepWhileMobileConnected)

        // Agent observation (per-workspace change streams, tab list
        // subscriptions, and the census scan) stays fully off unless the
        // default-off agents setting is on, so non-opted-in users pay no
        // per-agent-event or per-defaults-change fanout.
        var runningAgentCount = 0
        if agentsSettingEnabled {
            let workspaces = openWorkspaces(tabsOverride: tabsOverride)
            refreshTabManagerObservers()
            attachAgentObservers(to: workspaces)
            runningAgentCount = SleepyAgentCensus.runningAgentCount(in: workspaces)
        } else {
            cancelAgentObservation()
        }

        let desired = preventSleepDesired(
            agentsSettingEnabled: agentsSettingEnabled,
            mobileSettingEnabled: mobileSettingEnabled,
            runningAgentCount: runningAgentCount,
            mobileConnectionCount: MobileHostService.shared.statusSnapshot().activeConnectionCount
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
                self?.syncNow()
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

    private func attachAgentObservers(to workspaces: [Workspace]) {
        let models = workspaces.map(\.sidebarAgentRuntimeObservation)
        let currentIDs = Set(models.map(ObjectIdentifier.init))

        for id in agentObservationTasks.keys where !currentIDs.contains(id) {
            agentObservationTasks[id]?.cancel()
            agentObservationTasks[id] = nil
        }

        for model in models {
            let id = ObjectIdentifier(model)
            guard agentObservationTasks[id] == nil else { continue }
            agentObservationTasks[id] = Task { @MainActor [weak self, weak model] in
                guard let model else { return }
                for await _ in model.changes() {
                    if Task.isCancelled { break }
                    self?.syncNow()
                }
            }
        }
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
    }

    private func settingValue(_ key: DefaultsKey<Bool>) -> Bool {
        UserDefaults.standard.object(forKey: key.userDefaultsKey) as? Bool ?? key.defaultValue
    }
}
