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
    private var mobileObserver: NSObjectProtocol?
    private var mainWindowContextsObserver: NSObjectProtocol?
    private var agentObservationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var tabManagerCancellables: [ObjectIdentifier: AnyCancellable] = [:]

    private init() {}

    var isHoldingAssertion: Bool { assertion.isHeld }

    func start() {
        guard !isStarted else { return }
        isStarted = true
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
        if let mobileObserver {
            NotificationCenter.default.removeObserver(mobileObserver)
            self.mobileObserver = nil
        }
        if let mainWindowContextsObserver {
            NotificationCenter.default.removeObserver(mainWindowContextsObserver)
            self.mainWindowContextsObserver = nil
        }
        for task in agentObservationTasks.values {
            task.cancel()
        }
        agentObservationTasks.removeAll()
        for cancellable in tabManagerCancellables.values {
            cancellable.cancel()
        }
        tabManagerCancellables.removeAll()
        assertion.release()
    }

    func syncToSettings() {
        syncNow()
    }

    func syncNow(additionalWorkspaces: [Workspace] = []) {
        refreshTabManagerObservers()
        attachAgentObservers(additionalWorkspaces: additionalWorkspaces)
        reconcileAssertion()
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
                .sink { [weak self] tabs in
                    self?.syncNow(additionalWorkspaces: tabs)
                }
        }
    }

    private func attachAgentObservers(additionalWorkspaces: [Workspace]) {
        guard let app = AppDelegate.shared else { return }
        let models = (app.openWorkspacesForPetCensus() + additionalWorkspaces).map(\.sidebarAgentRuntimeObservation)
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

    private func reconcileAssertion() {
        let desired = preventSleepDesired(
            agentsSettingEnabled: settingValue(SettingCatalog().power.preventSleepWhileAgentsRunning),
            mobileSettingEnabled: settingValue(SettingCatalog().power.preventSleepWhileMobileConnected),
            runningAgentCount: SleepyAgentCensus.runningAgentCount(),
            mobileConnectionCount: MobileHostService.shared.statusSnapshot().activeConnectionCount
        )
        if desired {
            assertion.acquire()
        } else {
            assertion.release()
        }
    }

    private func settingValue(_ key: DefaultsKey<Bool>) -> Bool {
        UserDefaults.standard.object(forKey: key.userDefaultsKey) as? Bool ?? key.defaultValue
    }
}
