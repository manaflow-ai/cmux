import AppKit
import CmuxSubrouter

/// The app-side composition owner of the subrouter integration: constructs
/// the one ``SubrouterStore``, feeds it settings changes, and gates the
/// footer switcher's poll surface on app activity so a backgrounded app
/// never keeps the slow poll alive.
///
/// The Agents panel registers its own visibility directly with the store;
/// this runtime only owns the pieces no single view can (settings and app
/// activation).
@MainActor
final class SubrouterAppRuntime {
    static let shared = SubrouterAppRuntime()

    let store: SubrouterStore

    private var footerVisibleCount = 0
    private var agentsPanelVisibleCount = 0
    private var appIsActive = NSApp.isActive
    private var observationTasks: [Task<Void, Never>] = []

    /// The cached `sr server` default from `~/.subrouter/codex/servers.json`.
    /// Read once synchronously at init — the store must never start against
    /// the loopback endpoint while the registry selects a remote server, or
    /// an early socket `subrouter.switch` could pass the local-switch guard
    /// — then re-read off-main on app activation. The hot `UserDefaults`
    /// did-change path composes configuration from this cache instead of
    /// re-reading disk on every defaults write.
    private var serverSelection: SubrouterServerSelection.Server?

    /// Whether the last registry read found an existing but unreadable or
    /// undecodable `servers.json`. While set, the last valid selection is
    /// kept; with no last valid selection the configuration fails closed
    /// instead of assuming loopback.
    private var serverRegistryIsUnreadable = false

    /// The in-flight registry refresh. Concurrent callers coalesce onto the
    /// same read, so every awaiter of ``refreshServerSelectionAndApply()``
    /// returns only after a selection has actually been applied — a
    /// superseded caller must never proceed on the stale cache.
    private var selectionRefreshTask: Task<Void, Never>?

    private init() {
        let historyURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("cmux/subrouter-usage-history.json")
        store = SubrouterStore(historyStorageURL: historyURL)
        applyServerRegistryState(SubrouterIntegrationSettings.loadServerRegistryState())
        applyCurrentConfiguration()
        // Every switch entrypoint (panel, footer popover, socket) re-reads
        // sr's registry through the store's preflight so the remote-server
        // guard never trusts a cache from before an `sr server use` run.
        store.configurationPreflight = { [weak self] in
            await self?.refreshServerSelectionAndApply()
        }
        startObservers()
    }

    deinit {
        for task in observationTasks {
            task.cancel()
        }
        selectionRefreshTask?.cancel()
    }

    /// Called by the footer switcher button as it appears/disappears. The
    /// store's footer surface is visible only while at least one footer
    /// button is on screen *and* the app is active.
    func footerSwitcherDidAppear() {
        footerVisibleCount += 1
        syncFooterSurfaceVisibility()
    }

    /// See ``footerSwitcherDidAppear()``.
    func footerSwitcherDidDisappear() {
        footerVisibleCount = max(0, footerVisibleCount - 1)
        syncFooterSurfaceVisibility()
    }

    private func syncFooterSurfaceVisibility() {
        store.setSurfaceVisible(.footerSwitcher, footerVisibleCount > 0 && appIsActive)
    }

    /// Called by each window's Agents panel on a balanced show transition.
    /// Reference-counted like the footer switcher: several windows can show
    /// the panel against the one shared store, so one window hiding its
    /// sidebar must not stop polling for the others.
    func agentsPanelDidBecomeVisible() {
        agentsPanelVisibleCount += 1
        if agentsPanelVisibleCount == 1 {
            // Opening the panel is an authoritative boundary: pick up an
            // `sr server use` run while the app stayed active (activation
            // never fires when the change happens inside a cmux terminal).
            refreshServerSelection()
        }
        syncAgentsPanelSurfaceVisibility()
    }

    /// See ``agentsPanelDidBecomeVisible()``.
    func agentsPanelDidBecomeHidden() {
        agentsPanelVisibleCount = max(0, agentsPanelVisibleCount - 1)
        syncAgentsPanelSurfaceVisibility()
    }

    private func syncAgentsPanelSurfaceVisibility() {
        store.setSurfaceVisible(.agentsPanel, agentsPanelVisibleCount > 0)
    }

    private func applyCurrentConfiguration() {
        store.updateConfiguration(
            SubrouterIntegrationSettings.currentConfiguration(
                serverSelection: serverSelection,
                serverRegistryIsUnreadable: serverRegistryIsUnreadable
            )
        )
    }

    /// Folds one registry read into the cached selection. An unreadable
    /// registry keeps the last valid selection (it may hide a remote
    /// server) rather than silently reverting to the loopback daemon.
    private func applyServerRegistryState(_ state: SubrouterIntegrationSettings.ServerRegistryState) {
        switch state {
        case .selection(let server):
            serverSelection = server
            serverRegistryIsUnreadable = false
        case .unreadable:
            serverRegistryIsUnreadable = true
        }
    }

    /// Re-reads the `sr` server registry off the main actor, then reapplies
    /// configuration. `updateConfiguration` no-ops on equal values, so a
    /// selection that has not changed costs nothing beyond the read. Socket
    /// verbs await this before serving so `cmux subrouter …` always answers
    /// for the registry's current server.
    func refreshServerSelectionAndApply() async {
        // Single-flight: a second caller awaits the read already in
        // progress instead of racing it, so no awaiter can return while
        // nothing has been applied yet.
        if let selectionRefreshTask {
            await selectionRefreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            let state = await Task.detached(priority: .utility) {
                SubrouterIntegrationSettings.loadServerRegistryState()
            }.value
            guard let self else { return }
            self.applyServerRegistryState(state)
            self.applyCurrentConfiguration()
            self.selectionRefreshTask = nil
        }
        selectionRefreshTask = task
        await task.value
    }

    /// Fire-and-forget ``refreshServerSelectionAndApply()``.
    private func refreshServerSelection() {
        Task { @MainActor [weak self] in
            await self?.refreshServerSelectionAndApply()
        }
    }

    private func startObservers() {
        let center = NotificationCenter.default
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: UserDefaults.didChangeNotification).map({ _ in () }) {
                guard let self else { return }
                // updateConfiguration no-ops when the derived value is equal,
                // so the frequent defaults churn stays cheap. Composes from
                // the cached server selection: this fires on every defaults
                // write and must never touch disk.
                self.applyCurrentConfiguration()
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: .cmuxFeatureFlagsDidChange).map({ _ in () }) {
                guard let self else { return }
                self.applyCurrentConfiguration()
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: NSApplication.didBecomeActiveNotification).map({ _ in () }) {
                guard let self else { return }
                self.appIsActive = true
                // Endpoint resolution follows sr's servers.json, which is
                // not a defaults key — re-read it (off-main) on activation
                // so `sr server use` in a terminal is picked up when the
                // user returns.
                self.refreshServerSelection()
                self.syncFooterSurfaceVisibility()
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: NSApplication.willResignActiveNotification).map({ _ in () }) {
                guard let self else { return }
                self.appIsActive = false
                self.syncFooterSurfaceVisibility()
            }
        })
    }
}
