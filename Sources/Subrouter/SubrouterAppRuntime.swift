import AppKit
import CmuxFoundation
import CmuxSubrouter
import Darwin

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

    /// Synchronous availability mirror for nonisolated sidebar-mode callers.
    /// The store remains the source of truth; this publication only lets
    /// keyboard/restore paths read its gate without reaching across the main
    /// actor. Acquire/release ordering publishes applied transitions.
    private nonisolated static let runtimeEnabledSnapshot = AtomicBooleanGate(false)
    private nonisolated static let runtimeConfigurationKnownSnapshot = AtomicBooleanGate(false)

    nonisolated static var isRuntimeEnabled: Bool {
        runtimeEnabledSnapshot.loadAcquire()
    }

    /// Availability callers preserve a stored Agents selection until the
    /// asynchronous runtime has published its first authoritative config.
    /// The store itself remains disabled until that publication, so this
    /// temporary fail-open value cannot start network or account work.
    nonisolated static var isRuntimeEnabledForAvailability: Bool {
        !runtimeConfigurationKnownSnapshot.loadAcquire()
            || runtimeEnabledSnapshot.loadAcquire()
    }

    let store: SubrouterStore
    private let settings = SubrouterIntegrationSettings()

    private var footerVisibleCount = 0
    private var agentsPanelVisibleCount = 0
    private var appIsActive = NSApp.isActive
    private var observationTasks: [Task<Void, Never>] = []
    // File-system watch is active only while a Subrouter surface is visible;
    // `sr server use` edits the registry outside UserDefaults, so relying on
    // activation alone can leave a visible panel pinned to the old daemon.
    private var serverRegistryWatch: DispatchSourceFileSystemObject?

    /// The cached `sr server` default from `~/.subrouter/codex/servers.json`.
    /// Loaded off-main before any visible/socket surface is enabled — the
    /// store must never start against the loopback endpoint while the registry
    /// selects a remote server, or an early socket `subrouter.switch` could
    /// pass the local-switch guard. The hot `UserDefaults`
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
        // Usage-history persistence is opt-in until a UI consumer is wired;
        // constructing the runtime must not retain samples or write a file
        // that no visible surface reads.
        store = SubrouterStore()
        // Keep startup on the main actor free of registry disk I/O. The store
        // starts disabled and every visible/socket boundary awaits this
        // single-flight read before enabling work.
        Task { @MainActor [weak self] in
            await self?.refreshServerSelectionAndApply()
        }
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
        // `deinit` is nonisolated for a main-actor class; cancelling the
        // source directly avoids an actor hop while its cancel handler closes
        // the descriptor.
        serverRegistryWatch?.cancel()
    }

    /// Called by the footer switcher button as it appears/disappears. The
    /// store's footer surface is visible only while at least one footer
    /// button is on screen *and* the app is active.
    func footerSwitcherDidAppear() {
        footerVisibleCount += 1
        syncServerRegistryWatch()
        if footerVisibleCount == 1 {
            // Do not let the first background poll race a registry refresh.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshServerSelectionAndApply()
                guard self.footerVisibleCount > 0 else { return }
                self.syncFooterSurfaceVisibility()
            }
        } else {
            syncFooterSurfaceVisibility()
        }
    }

    /// See ``footerSwitcherDidAppear()``.
    func footerSwitcherDidDisappear() {
        footerVisibleCount = max(0, footerVisibleCount - 1)
        syncFooterSurfaceVisibility()
        syncServerRegistryWatch()
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
        syncServerRegistryWatch()
        if agentsPanelVisibleCount == 1 {
            // Opening the panel is an authoritative boundary: await the
            // registry read before enabling its poll surface, so the first
            // request cannot hit loopback while `sr server use` selects a
            // remote daemon.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshServerSelectionAndApply()
                guard self.agentsPanelVisibleCount > 0 else { return }
                self.syncAgentsPanelSurfaceVisibility()
            }
        } else {
            syncAgentsPanelSurfaceVisibility()
        }
    }

    /// See ``agentsPanelDidBecomeVisible()``.
    func agentsPanelDidBecomeHidden() {
        agentsPanelVisibleCount = max(0, agentsPanelVisibleCount - 1)
        syncAgentsPanelSurfaceVisibility()
        syncServerRegistryWatch()
    }

    private func syncAgentsPanelSurfaceVisibility() {
        store.setSurfaceVisible(.agentsPanel, agentsPanelVisibleCount > 0 && appIsActive)
    }

    /// Watches the directory containing `servers.json` while a Subrouter UI
    /// surface is visible. The event source is the low-level file-watching
    /// seam; its handler only schedules the existing single-flight, off-main
    /// registry read and never performs disk I/O on the callback queue.
    private func syncServerRegistryWatch() {
        let shouldWatch = appIsActive
            && (agentsPanelVisibleCount > 0 || footerVisibleCount > 0)
        if shouldWatch {
            startServerRegistryWatchIfNeeded()
        } else {
            stopServerRegistryWatch()
        }
    }

    private func startServerRegistryWatchIfNeeded() {
        guard serverRegistryWatch == nil else { return }
        let registryURL = SubrouterIntegrationSettings.serverRegistryURL()
        let codexDirectory = registryURL.deletingLastPathComponent()
        let subrouterDirectory = codexDirectory.deletingLastPathComponent()
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        // Watch the nearest existing parent on first run. Setup may create
        // `.subrouter/codex` after the panel is already visible; the parent
        // event then triggers a refresh and this method re-arms on codex.
        let registryDirectory: URL
        if FileManager.default.fileExists(atPath: codexDirectory.path) {
            registryDirectory = codexDirectory
        } else if FileManager.default.fileExists(atPath: subrouterDirectory.path) {
            registryDirectory = subrouterDirectory
        } else {
            registryDirectory = homeDirectory
        }
        let descriptor = open(registryDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshServerSelectionAndApply()
                // An atomic replace can invalidate the watched directory;
                // re-arm against the current path after every event.
                self.stopServerRegistryWatch()
                self.startServerRegistryWatchIfNeeded()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        serverRegistryWatch = source
        source.resume()
    }

    private func stopServerRegistryWatch() {
        guard let source = serverRegistryWatch else { return }
        serverRegistryWatch = nil
        source.cancel()
    }

    private func applyCurrentConfiguration() {
        let configuration = settings.currentConfiguration(
            serverSelection: serverSelection,
            serverRegistryIsUnreadable: serverRegistryIsUnreadable
        )
        store.updateConfiguration(configuration)
        Self.runtimeEnabledSnapshot.storeRelease(configuration.isEnabled)
        Self.runtimeConfigurationKnownSnapshot.storeRelease(true)
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
                // Do not re-enable a visible surface until the off-main
                // registry read has applied. Otherwise the first activation
                // poll can briefly hit the daemon selected before `sr server
                // use` was run in a terminal.
                await self.refreshServerSelectionAndApply()
                self.syncServerRegistryWatch()
                self.syncAgentsPanelSurfaceVisibility()
                self.syncFooterSurfaceVisibility()
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: NSApplication.willResignActiveNotification).map({ _ in () }) {
                guard let self else { return }
                self.appIsActive = false
                self.syncAgentsPanelSurfaceVisibility()
                self.syncFooterSurfaceVisibility()
                self.syncServerRegistryWatch()
            }
        })
    }
}
