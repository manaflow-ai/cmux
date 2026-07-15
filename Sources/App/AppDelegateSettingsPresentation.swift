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
            ?? activeTabManagerForCommands(preferredWindow: targetWindow) else {
#if DEBUG
            cmuxDebugLog("appUtility.open.failed source=\(debugSource) kind=\(kind.rawValue)")
#endif
            return false
        }
        let workspace = appUtilityTargetWorkspace(
            in: targetTabs,
            select: activateApplication
        )
        guard let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
#if DEBUG
            cmuxDebugLog("appUtility.open.failed source=\(debugSource) kind=\(kind.rawValue)")
#endif
            return false
        }

        if activateApplication {
            workspace.clearSplitZoom()
        }
        guard workspace.openOrFocusAppUtilityPane(
            fromPane: paneId,
            kind: kind,
            settingsNavigationTarget: settingsNavigationTarget,
            focus: activateApplication
        ) != nil else {
            return false
        }

        let hostWindow = [targetTabs.window, targetWindow]
            .compactMap { $0 }
            .first { contextForMainWindow($0)?.tabManager === targetTabs }
        if let hostWindow {
            presentAppUtilityHostWindow(hostWindow, activateApplication: activateApplication)
        }
#if DEBUG
        cmuxDebugLog("appUtility.open.succeeded source=\(debugSource) kind=\(kind.rawValue)")
#endif
        return true
    }

    /// Utility panes cannot join a remote-tmux mirror's server-owned split
    /// topology. Keep them in the same window by using a local workspace,
    /// creating one in the same tab manager only when none exists. A
    /// nonactivating request must not change the visible workspace selection.
    func appUtilityTargetWorkspace(in tabManager: TabManager, select: Bool = true) -> Workspace {
        if let selectedWorkspace = tabManager.selectedWorkspace,
           !selectedWorkspace.isRemoteTmuxMirror {
            return selectedWorkspace
        }
        if let localWorkspace = tabManager.tabs.first(where: { !$0.isRemoteTmuxMirror }) {
            if select {
                tabManager.selectWorkspace(localWorkspace)
            }
            return localWorkspace
        }
        return tabManager.addWorkspace(
            inheritWorkingDirectory: false,
            select: select,
            autoWelcomeIfNeeded: false
        )
    }

    func presentAppUtilityHostWindow(_ window: NSWindow, activateApplication: Bool) {
        if let mainWindow = window as? CmuxMainWindow {
            mainWindow.setSoftHiddenForVisibilityController(false)
        } else {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if activateApplication {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }
}
