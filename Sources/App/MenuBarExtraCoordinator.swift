import AppKit
import Foundation
import Observation

/// Owns the menu-bar status item lifecycle and the application-presentation
/// preferences that depend on it (activation policy, menu-bar-extra visibility,
/// and the global-search palette entry points).
///
/// Extracted from ``AppDelegate`` so the menu-bar-extra state (the persistent
/// controller, the transient global-search controller, the visibility observer,
/// and the last-installed flag) lives with the logic that drives it instead of
/// on the app-delegate singleton. The few app-delegate actions the status menu
/// invokes (show main window, show notifications, open a notification, jump to
/// latest unread, check for updates, open preferences) are injected as a
/// ``Callbacks`` closure seam, so this coordinator never reaches back into the
/// app delegate. ``MenuBarExtraController`` and the
/// `GlobalSearchCoordinator`/`TaskManagerWindowController` singletons stay
/// app-side and are referenced directly.
@MainActor
@Observable
final class MenuBarExtraCoordinator {
    /// The app-delegate actions the status menu invokes, injected so the
    /// coordinator does not depend on ``AppDelegate``.
    struct Callbacks {
        let showMainWindow: () -> Void
        let showNotifications: () -> Void
        let openNotification: (TerminalNotification) -> Void
        let jumpToLatestUnread: () -> Void
        let checkForUpdates: () -> Void
        let openPreferences: () -> Void

        init(
            showMainWindow: @escaping () -> Void,
            showNotifications: @escaping () -> Void,
            openNotification: @escaping (TerminalNotification) -> Void,
            jumpToLatestUnread: @escaping () -> Void,
            checkForUpdates: @escaping () -> Void,
            openPreferences: @escaping () -> Void
        ) {
            self.showMainWindow = showMainWindow
            self.showNotifications = showNotifications
            self.openNotification = openNotification
            self.jumpToLatestUnread = jumpToLatestUnread
            self.checkForUpdates = checkForUpdates
            self.openPreferences = openPreferences
        }
    }

    private let callbacks: Callbacks
    private var menuBarVisibilityObserver: NSObjectProtocol?
    private var menuBarExtraController: MenuBarExtraController?
    private var transientGlobalSearchMenuBarExtraController: MenuBarExtraController?
    private var lastMenuBarExtraShouldInstall: Bool?

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    private func setupMenuBarExtra() {
        guard menuBarExtraController == nil else { return }
        removeTransientGlobalSearchMenuBarExtraController()
        menuBarExtraController = makeMenuBarExtraController()
    }

    private func makeMenuBarExtraController() -> MenuBarExtraController {
        let store = TerminalNotificationStore.shared
        return MenuBarExtraController(
            notificationStore: store,
            onShowGlobalSearch: { button, onDismiss in
                GlobalSearchCoordinator.shared.togglePalette(anchor: button, onDismiss: onDismiss)
            },
            onShowMainWindow: { [weak self] in
                self?.callbacks.showMainWindow()
            },
            onShowNotifications: { [weak self] in
                self?.callbacks.showNotifications()
            },
            onOpenNotification: { [weak self] notification in
                self?.callbacks.openNotification(notification)
            },
            onJumpToLatestUnread: { [weak self] in
                self?.callbacks.jumpToLatestUnread()
            },
            onOpenTaskManager: {
                TaskManagerWindowController.shared.show()
            },
            onCheckForUpdates: { [weak self] in
                self?.callbacks.checkForUpdates()
            },
            onOpenPreferences: { [weak self] in
                self?.callbacks.openPreferences()
            },
            onQuitApp: {
                NSApp.terminate(nil)
            }
        )
    }

    func toggleGlobalSearchPaletteFromGlobalHotkey() {
        if menuBarExtraController == nil,
           MenuBarExtraSettings.shouldInstallMenuBarExtra() {
            setupMenuBarExtra()
        }

        if let menuBarExtraController,
           menuBarExtraController.toggleGlobalSearchPalette() {
            return
        }

        if toggleGlobalSearchPaletteFromTransientMenuBarExtra() {
            return
        }

        NSSound.beep()
    }

    private func toggleGlobalSearchPaletteFromTransientMenuBarExtra() -> Bool {
        if let controller = transientGlobalSearchMenuBarExtraController {
            if controller.toggleGlobalSearchPalette(
                onDismiss: transientGlobalSearchDismissalHandler(for: controller)
            ) {
                return true
            }
            controller.removeFromMenuBar()
            transientGlobalSearchMenuBarExtraController = nil
        }

        let controller = makeMenuBarExtraController()
        transientGlobalSearchMenuBarExtraController = controller

        let onDismiss = transientGlobalSearchDismissalHandler(for: controller)

        guard controller.toggleGlobalSearchPalette(onDismiss: onDismiss) else {
            controller.removeFromMenuBar()
            transientGlobalSearchMenuBarExtraController = nil
            return false
        }

        return true
    }

    private func removeTransientGlobalSearchMenuBarExtraController() {
        transientGlobalSearchMenuBarExtraController?.removeFromMenuBar()
        transientGlobalSearchMenuBarExtraController = nil
    }

    private func transientGlobalSearchDismissalHandler(
        for controller: MenuBarExtraController
    ) -> () -> Void {
        return { [weak self, weak controller] in
            guard let self,
                  let controller,
                  self.transientGlobalSearchMenuBarExtraController === controller else {
                return
            }
            controller.removeFromMenuBar()
            self.transientGlobalSearchMenuBarExtraController = nil
        }
    }

    func installMenuBarVisibilityObserver() {
        guard menuBarVisibilityObserver == nil else { return }
        menuBarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncApplicationPresentationPreferences()
            }
        }
    }

    func syncApplicationPresentationPreferences(defaults: UserDefaults = .standard) {
        MenuBarOnlySettings.normalizeLegacyStoredPreference(defaults: defaults)
        syncActivationPolicy(defaults: defaults)
        syncMenuBarExtraVisibility(defaults: defaults)
    }

    func syncActivationPolicy(defaults: UserDefaults = .standard) {
        MenuBarOnlySettings.applyActivationPolicy(defaults: defaults)
    }

    private func syncMenuBarExtraVisibility(defaults: UserDefaults = .standard) {
        let shouldInstall = MenuBarExtraSettings.shouldInstallMenuBarExtra(defaults: defaults)
        let previousShouldInstall = lastMenuBarExtraShouldInstall
        lastMenuBarExtraShouldInstall = shouldInstall

        if shouldInstall {
            setupMenuBarExtra()
            return
        }

        let hadPersistentController = menuBarExtraController != nil
        menuBarExtraController?.removeFromMenuBar()
        menuBarExtraController = nil
        if previousShouldInstall == true || hadPersistentController {
            removeTransientGlobalSearchMenuBarExtraController()
        }
    }

    func refreshMenuBarExtraForDebug() {
        menuBarExtraController?.refreshForDebugControls()
    }
}
