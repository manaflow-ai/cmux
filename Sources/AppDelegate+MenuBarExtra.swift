import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Menu bar extra, preferences window, and app visibility
extension AppDelegate {
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
                self?.showMainWindowFromMenuBar()
            },
            onShowNotifications: { [weak self] in
                self?.showNotificationsPopoverFromMenuBar()
            },
            onOpenNotification: { [weak self] notification in
                _ = self?.openTerminalNotification(notification)
            },
            onJumpToLatestUnread: { [weak self] in
                self?.jumpToLatestUnread()
            },
            onOpenTaskManager: {
                TaskManagerWindowController.shared.show()
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates(nil)
            },
            onOpenPreferences: { [weak self] in
                self?.openPreferencesWindow(debugSource: "menuBarExtra")
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
        syncActivationPolicy(defaults: defaults)
        syncMenuBarExtraVisibility(defaults: defaults)
    }

    func installMobileHostSettingsObserver() {
        guard mobileHostSettingsObserver == nil else { return }
        mobileHostSettingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMobileHostService()
            }
        }
    }

    private func syncMobileHostService() {
        MobileHostService.shared.syncToSettings()
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

    @MainActor
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        showFallbackSettingsWindow: @MainActor (SettingsNavigationTarget?) -> Void = { target in
            SettingsWindowPresenter.show(navigationTarget: target)
        },
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    ) {
#if DEBUG
        cmuxDebugLog("settings.open.present path=swiftuiWindow")
#endif
        showFallbackSettingsWindow(navigationTarget)
        activateApplication()
#if DEBUG
        cmuxDebugLog("settings.open.present activate=1")
#endif
    }

    @MainActor
    func openPreferencesWindow(debugSource: String, navigationTarget: SettingsNavigationTarget? = nil) {
#if DEBUG
        cmuxDebugLog("settings.open.request source=\(debugSource)")
#endif
        Self.presentPreferencesWindow(navigationTarget: navigationTarget)
    }

    @objc func openPreferencesWindow() {
        openPreferencesWindow(debugSource: "appDelegate")
    }

    func refreshMenuBarExtraForDebug() {
        menuBarExtraController?.refreshForDebugControls()
    }

    func captureMainWindowVisibilityRestoreTargetsForApplicationHide() {
        mainWindowVisibilityController.captureHiddenWindowRestoreTargets(windows: mainWindowsForVisibilityController())
    }

    func toggleApplicationVisibilityFromGlobalHotkey() {
        mainWindowVisibilityController.toggleApplicationVisibility(
            windows: mainWindowsForVisibilityController(),
            reason: .globalHotkey
        )
    }

    @discardableResult
    func focusWindowForAppActivation(
        _ window: NSWindow,
        reason: MainWindowVisibilityController.Reason
    ) -> Bool {
        mainWindowVisibilityController.focus(
            window,
            reason: reason,
            activation: .runningApplication([.activateAllWindows]),
            respectActivationSuppression: false
        )
    }

    func preferredMainWindowForVisibilityActivation() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow,
           isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        if let visibleContext = sortedMainWindowContextsForSessionSnapshot().first(where: { context in
            guard let window = resolvedWindow(for: context) else { return false }
            return window.isVisible && !window.isMiniaturized
        }) {
            return resolvedWindow(for: visibleContext)
        }
        return sortedMainWindowContextsForSessionSnapshot()
            .compactMap { resolvedWindow(for: $0) }
            .first
    }

    @MainActor
    func preferredMainWindowForSettingsPresentation() -> NSWindow? {
        preferredMainWindowForVisibilityActivation()
    }

    @discardableResult func showMainWindowFromMenuBar() -> NSWindow? {
        if let window = mainWindowVisibilityController.showApplicationWindows(
            windows: mainWindowsForVisibilityController(),
            reason: .menuBar
        ) {
            return window
        }

        let windowId = ensureInitialMainWindowIfNeeded(shouldActivate: false)
        guard let window = windowForMainWindowId(windowId) else {
            NSSound.beep()
            return nil
        }
        _ = mainWindowVisibilityController.focus(
            window,
            reason: .menuBar,
            respectActivationSuppression: false
        )
        return window
    }

    func mainWindowsForVisibilityController() -> [NSWindow] {
        var windows: [NSWindow] = []
        for context in sortedMainWindowContextsForSessionSnapshot() {
            guard let window = resolvedWindow(for: context) else { continue }
            if !windows.contains(where: { $0 === window }) {
                windows.append(window)
            }
        }
        for window in NSApp.windows where isMainTerminalWindow(window) {
            if !windows.contains(where: { $0 === window }) {
                windows.append(window)
            }
        }
        return windows
    }

    func showNotificationsPopoverFromMenuBar() {
        let context: MainWindowContext? = {
            if let keyWindow = NSApp.keyWindow,
               let keyContext = contextForMainTerminalWindow(keyWindow) {
                return keyContext
            }
            if let first = mainWindowContexts.values.first {
                return first
            }
            let windowId = createMainWindow()
            return mainWindowContexts.values.first(where: { $0.windowId == windowId })
        }()

        if let context,
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.titlebarAccessoryController.showNotificationsPopover(animated: false)
        }
    }

}
