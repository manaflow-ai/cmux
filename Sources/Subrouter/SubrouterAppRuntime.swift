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

    private init() {
        store = SubrouterStore()
        store.updateConfiguration(SubrouterIntegrationSettings.currentConfiguration())
        startObservers()
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

    private func startObservers() {
        let center = NotificationCenter.default
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: UserDefaults.didChangeNotification).map({ _ in () }) {
                guard let self else { return }
                // updateConfiguration no-ops when the derived value is equal,
                // so the frequent defaults churn stays cheap.
                self.store.updateConfiguration(SubrouterIntegrationSettings.currentConfiguration())
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: .cmuxFeatureFlagsDidChange).map({ _ in () }) {
                guard let self else { return }
                self.store.updateConfiguration(SubrouterIntegrationSettings.currentConfiguration())
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: NSApplication.didBecomeActiveNotification).map({ _ in () }) {
                guard let self else { return }
                self.appIsActive = true
                // Endpoint resolution follows sr's servers.json, which is
                // not a defaults key — re-derive on activation so `sr server
                // use` in a terminal is picked up when the user returns.
                self.store.updateConfiguration(SubrouterIntegrationSettings.currentConfiguration())
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
