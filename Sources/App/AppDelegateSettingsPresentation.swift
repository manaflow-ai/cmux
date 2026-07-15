import AppKit

/// The Settings-open entrypoints shared by the app menu, ⌘,, the command
/// palette, help commands, and the menu-bar extra. Split out of
/// `AppDelegate.swift` (file-length budget) alongside the AppKit-owned
/// Settings presentation lifecycle (https://github.com/manaflow-ai/cmux/issues/7777).
extension AppDelegate {
    @MainActor
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        // Test seam only; a substitute presenter must still report a
        // `SettingsWindowShowResult`, so there is no alternate path that can
        // claim success without a verified window (the #7775 failure shape).
        presentSettingsWindow: (@MainActor (SettingsNavigationTarget?) -> SettingsWindowShowResult)? = nil,
        // The legacy body also passed .activateIgnoringOtherApps; the option
        // is deprecated and documented as a no-op on macOS 14+ (this target's
        // minimum), so dropping it is behavior-neutral.
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
    ) {
        if presentSettingsWindow == nil {
            guard let appDelegate = AppDelegate.shared else {
                NSSound.beep()
                return
            }
            _ = appDelegate.openPreferencesWindow(
                debugSource: "static.presentPreferencesWindow",
                navigationTarget: navigationTarget
            )
            return
        }
#if DEBUG
        cmuxDebugLog("settings.open.present path=injectedAppKitWindow")
#endif
        guard let present = presentSettingsWindow else { return }
        if case .failed = present(navigationTarget) {
            // The presenter already logged the loud failure diagnostics;
            // surface the failed menu/⌘, action instead of silently activating.
            NSSound.beep()
            return
        }
        activateApplication()
#if DEBUG
        cmuxDebugLog("settings.open.present activate=1")
#endif
    }

    @MainActor
    @discardableResult
    func openPreferencesWindow(
        debugSource: String,
        navigationTarget: SettingsNavigationTarget? = nil,
        activateApplication: Bool = true
    ) -> Bool {
#if DEBUG
        cmuxDebugLog("settings.open.request source=\(debugSource)")
#endif
        guard openAppUtilityPane(
            kind: .settings,
            debugSource: debugSource,
            settingsNavigationTarget: navigationTarget,
            activateApplication: activateApplication
        ) else {
            NSSound.beep()
            return false
        }
        return true
    }

    @objc func openPreferencesWindow() {
        openPreferencesWindow(debugSource: "appDelegate")
    }

    func toggleFocusedSettingsPaneSidebar(tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let panel = workspace.panels[focusedPanelId] as? AppUtilityPanel,
              panel.kind == .settings else {
            return false
        }
        SettingsWindowPresenter.requestSidebarToggle(scope: panel.settingsNavigationScope)
        return true
    }

    func toggleSidebar(in context: MainWindowContext) {
        guard !toggleFocusedSettingsPaneSidebar(tabManager: context.tabManager) else { return }
        context.sidebarState.toggle()
    }

    @discardableResult
    func openMobilePairingPane(
        debugSource: String,
        tabManager explicitTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        openAppUtilityPane(
            kind: .mobilePairing,
            debugSource: debugSource,
            tabManager: explicitTabManager,
            preferredWindow: preferredWindow
        )
    }

    @discardableResult
    private func openAppUtilityPane(
        kind: AppUtilityPanelKind,
        debugSource: String,
        settingsNavigationTarget: SettingsNavigationTarget? = nil,
        tabManager explicitTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil,
        activateApplication: Bool = true
    ) -> Bool {
        let candidateWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let targetWindow: NSWindow? = if explicitTabManager != nil {
            candidateWindow
        } else if contextForMainWindow(candidateWindow) != nil {
            candidateWindow
        } else if let existingWindow = preferredMainWindowForSettingsPresentation() {
            existingWindow
        } else if activateApplication {
            showMainWindowFromMenuBar()
        } else {
            windowForMainWindowId(ensureInitialMainWindowIfNeeded(shouldActivate: false))
        }
        guard let targetTabs = explicitTabManager
            ?? activeTabManagerForCommands(preferredWindow: targetWindow),
              let workspace = targetTabs.selectedWorkspace
                ?? targetTabs.tabs.first,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
#if DEBUG
            cmuxDebugLog("appUtility.open.failed source=\(debugSource) kind=\(kind.rawValue)")
#endif
            return false
        }

        workspace.clearSplitZoom()
        guard workspace.openOrFocusAppUtilityPane(
            fromPane: paneId,
            kind: kind,
            settingsNavigationTarget: settingsNavigationTarget,
            focus: true
        ) != nil else {
            return false
        }

        if activateApplication, let targetWindow, contextForMainWindow(targetWindow) != nil {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            if targetWindow.isMiniaturized {
                targetWindow.deminiaturize(nil)
            }
            targetWindow.makeKeyAndOrderFront(nil)
        }
#if DEBUG
        cmuxDebugLog("appUtility.open.succeeded source=\(debugSource) kind=\(kind.rawValue)")
#endif
        return true
    }
}
