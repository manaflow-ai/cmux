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
    private var appIsActive = NSApp.isActive
    private var observationTasks: [Task<Void, Never>] = []

    /// The cached `sr server` default from `~/.subrouter/codex/servers.json`.
    /// Loaded off-main at init and on app activation; the hot
    /// `UserDefaults` did-change path composes configuration from this
    /// cache instead of re-reading disk on every defaults write.
    private var serverSelection: SubrouterServerSelection.Server?

    private init() {
        let historyURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("cmux/subrouter-usage-history.json")
        store = SubrouterStore(historyStorageURL: historyURL)
        applyCurrentConfiguration()
        startObservers()
        refreshServerSelection()
    }

    deinit {
        for task in observationTasks {
            task.cancel()
        }
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

    private func applyCurrentConfiguration() {
        store.updateConfiguration(
            SubrouterIntegrationSettings.currentConfiguration(serverSelection: serverSelection)
        )
    }

    /// Re-reads the `sr` server registry off the main actor, then reapplies
    /// configuration. `updateConfiguration` no-ops on equal values, so a
    /// selection that has not changed costs nothing beyond the read.
    private func refreshServerSelection() {
        Task { @MainActor [weak self] in
            let selection = await Task.detached(priority: .utility) {
                SubrouterIntegrationSettings.loadDefaultServerSelection()
            }.value
            guard let self else { return }
            self.serverSelection = selection
            self.applyCurrentConfiguration()
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
