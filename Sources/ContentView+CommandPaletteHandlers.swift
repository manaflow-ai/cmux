import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Command palette handler registration and configured actions
extension ContentView {
    func registerCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newWorkspace") {
            AppDelegate.shared?.performNewWorkspaceAction(
                tabManager: tabManager,
                debugSource: "palette.newWorkspace"
            )
        }
        registry.register(commandId: "palette.openFolder") {
            // Defer so the command palette dismisses before the modal sheet appears.
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = String(localized: "panel.openFolder.title", defaultValue: "Open Folder")
                panel.prompt = String(localized: "panel.openFolder.prompt", defaultValue: "Open")
                if panel.runModal() == .OK, let url = panel.url {
                    tabManager.addWorkspace(workingDirectory: url.path)
                }
            }
        }
        registry.register(commandId: "palette.openFolderInVSCodeInline") {
            DispatchQueue.main.async {
                AppDelegate.shared?.showOpenFolderInInlineVSCodePanel(tabManager: tabManager)
            }
        }
        registry.register(commandId: "palette.reopenPreviousSession") {
            if AppDelegate.shared?.reopenPreviousSession() != true {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.newWindow") {
            guard let appDelegate = AppDelegate.shared else { return }
            appDelegate.openNewMainWindow(preferredWindow: appDelegate.mainWindow(for: windowId))
        }
        registry.register(commandId: "palette.installCLI") {
            AppDelegate.shared?.installCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.uninstallCLI") {
            AppDelegate.shared?.uninstallCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.newTerminalTab") {
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.newTerminal.configID) {
                tabManager.newSurface()
            }
        }
        registry.register(commandId: "palette.newBrowserTab") {
            if executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.newBrowser.configID) {
                return
            }
            // Let command-palette dismissal complete first so omnibar focus
            // is not blocked by the palette visibility guard.
            DispatchQueue.main.async {
                _ = AppDelegate.shared?.openBrowserAndFocusAddressBar()
            }
        }
        registry.register(commandId: "palette.closeTab") {
            tabManager.closeCurrentPanelWithConfirmation()
        }
        registry.register(commandId: "palette.closeWorkspace") {
            tabManager.closeCurrentWorkspaceWithConfirmation()
        }
        registry.register(commandId: "palette.closeWindow") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            if let appDelegate = AppDelegate.shared {
                appDelegate.closeWindowWithConfirmation(window)
            } else {
                window.performClose(nil)
            }
        }
        registry.register(commandId: "palette.toggleFullScreen") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            window.toggleFullScreen(nil)
        }
        registry.register(commandId: "palette.reopenClosedBrowserTab") {
            if let appDelegate = AppDelegate.shared {
                _ = appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: tabManager)
            } else {
                _ = tabManager.reopenMostRecentlyClosedItem()
            }
        }
        registry.register(commandId: "palette.toggleSidebar") {
            sidebarState.toggle()
        }
        // Register a handler for every possible view (including the hosted
        // extension sidebar) regardless of the beta flag, so a contribution that
        // was visible when the flag was on still resolves after a runtime flip.
        // Visibility is gated by `descriptors`; the handler set is the superset.
        for descriptor in CmuxExtensionSidebarSelection.allDescriptors {
            registry.register(commandId: commandPaletteExtensionSidebarCommandID(descriptor.id)) {
                CmuxExtensionSidebarSelection.setProviderId(descriptor.id)
            }
        }
        for mode in RightSidebarMode.allCases {
            registry.register(commandId: Self.commandPaletteRightSidebarModeCommandID(mode)) {
                handleCommandPaletteRightSidebarMode(mode, observedWindow: observedWindow)
            }
        }
        for descriptor in Self.commandPaletteRightSidebarToolPaneCommandDescriptors() {
            registry.register(commandId: descriptor.commandId) {
                handleCommandPaletteRightSidebarToolPane(descriptor.mode)
            }
        }
        registry.register(commandId: "palette.toggleMatchTerminalBackground") {
            sidebarMatchTerminalBackground.toggle()
        }
        registry.register(commandId: "palette.enableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.minimal.rawValue
        }
        registry.register(commandId: "palette.disableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.standard.rawValue
        }
        registerViewCommandHandlers(&registry)
        registry.register(commandId: "palette.showNotifications") {
            AppDelegate.shared?.toggleNotificationsPopover(animated: false)
        }
        registry.register(commandId: "palette.jumpUnread") {
            AppDelegate.shared?.jumpToLatestUnread()
        }
        registry.register(commandId: "palette.toggleUnread") {
            AppDelegate.shared?.toggleFocusedNotificationUnread(
                preferredWindow: observedWindow
            )
        }
        registry.register(commandId: "palette.markOldestUnreadAndJumpNext") {
            AppDelegate.shared?.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
                preferredWindow: observedWindow
            )
        }
        registry.register(commandId: "palette.openSettings") {
#if DEBUG
            cmuxDebugLog("palette.openSettings.invoke")
#endif
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(debugSource: "palette.openSettings")
            } else {
#if DEBUG
                cmuxDebugLog("palette.openSettings.missingAppDelegate fallback=1")
#endif
                AppDelegate.presentPreferencesWindow()
            }
        }
        registry.register(commandId: "palette.openCmuxSettingsFile") {
#if DEBUG
            cmuxDebugLog("palette.openCmuxSettingsFile.invoke")
#endif
            openCmuxSettingsFileInEditor()
        }
        registry.register(commandId: "palette.openGhosttySettings") {
#if DEBUG
            cmuxDebugLog("palette.openGhosttySettings.invoke")
#endif
            GhosttyApp.shared.openConfigurationInTextEdit()
        }
        registry.register(commandId: "palette.mobileConnect") {
#if DEBUG
            cmuxDebugLog("palette.mobileConnect.invoke")
#endif
            MobilePairingWindowController.shared.show()
        }
        registerAuthCommandHandlers(&registry)
        registry.register(commandId: "palette.makeDefaultTerminal") {
            DefaultTerminalUserAction.setAsDefault(debugSource: "palette.makeDefaultTerminal")
        }
        registry.register(commandId: "palette.checkForUpdates") {
            AppDelegate.shared?.checkForUpdates(nil)
        }
        registry.register(commandId: "palette.applyUpdateIfAvailable") {
            AppDelegate.shared?.applyUpdateIfAvailable(nil)
        }
        registry.register(commandId: "palette.attemptUpdate") {
            AppDelegate.shared?.attemptUpdate(nil)
        }
        registry.register(commandId: "palette.restartSocketListener") {
            AppDelegate.shared?.restartSocketListener(nil)
        }
        registry.register(commandId: "palette.disableBrowser") {
            BrowserAvailabilitySettings.setDisabled(true)
        }
        registry.register(commandId: "palette.enableBrowser") {
            BrowserAvailabilitySettings.setDisabled(false)
        }
        registerSettingsToggleCommandHandlers(&registry)

        registry.register(commandId: "palette.renameWorkspace") {
            beginRenameWorkspaceFlow()
        }
        registry.register(commandId: "palette.editWorkspaceDescription") {
            beginWorkspaceDescriptionFlow()
        }
        registry.register(commandId: "palette.clearWorkspaceName") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomTitle(tabId: workspace.id)
        }
        registry.register(commandId: "palette.clearWorkspaceDescription") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomDescription(tabId: workspace.id)
        }
        registry.register(commandId: "palette.toggleWorkspacePin") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            let pinTarget = WorkspaceActionDispatcher.Target.single(workspace.id)
            guard WorkspaceActionDispatcher.performPinAction(in: tabManager, target: pinTarget) != nil else {
                NSSound.beep()
                return
            }
        }
        registry.register(commandId: "palette.resetWorkspaceColor") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.applyWorkspaceColor(nil, toWorkspaceIds: [workspace.id])
        }
        for entry in WorkspaceTabColorSettings.palette() {
            registry.register(commandId: commandPaletteWorkspaceColorCommandID(entry.name)) {
                guard let workspace = tabManager.selectedWorkspace else {
                    NSSound.beep()
                    return
                }
                tabManager.applyWorkspacePaletteColor(named: entry.name, toWorkspaceIds: [workspace.id])
            }
        }
        registry.register(commandId: "palette.nextWorkspace") {
            tabManager.selectNextTab()
        }
        registry.register(commandId: "palette.previousWorkspace") {
            tabManager.selectPreviousTab()
        }
        registry.register(commandId: "palette.moveWorkspaceUp") {
            moveSelectedWorkspace(by: -1)
        }
        registry.register(commandId: "palette.moveWorkspaceDown") {
            moveSelectedWorkspace(by: 1)
        }
        registry.register(commandId: "palette.moveWorkspaceToTop") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.moveTabsToTop([workspace.id])
            tabManager.selectWorkspace(workspace)
        }
        registry.register(commandId: "palette.closeOtherWorkspaces") {
            closeOtherSelectedWorkspaces()
        }
        registry.register(commandId: "palette.closeWorkspacesBelow") {
            closeSelectedWorkspacesBelow()
        }
        registry.register(commandId: "palette.closeWorkspacesAbove") {
            closeSelectedWorkspacesAbove()
        }
        registry.register(commandId: "palette.markWorkspaceRead") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markRead(forTabId: workspaceId)
        }
        registry.register(commandId: "palette.markWorkspaceUnread") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markUnread(forTabId: workspaceId)
        }
        registerIdentifierCopyCommandHandlers(&registry)

        registry.register(commandId: "palette.renameTab") {
            beginRenameTabFlow()
        }
        registry.register(commandId: "palette.clearTabName") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelCustomTitle(panelId: panelContext.panelId, title: nil)
        }
        registry.register(commandId: "palette.moveTabToNewWorkspace") {
            guard moveFocusedPanelToNewWorkspace() else { NSSound.beep(); return }
        }
        registry.register(commandId: "palette.toggleTabPin") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelPinned(
                panelId: panelContext.panelId,
                pinned: !panelContext.workspace.isPanelPinned(panelContext.panelId)
            )
        }
        registry.register(commandId: "palette.toggleTabUnread") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            let hasUnread = panelContext.workspace.manualUnreadPanelIds.contains(panelContext.panelId) ||
                panelContext.workspace.restoredUnreadPanelIds.contains(panelContext.panelId) ||
                notificationStore.hasUnreadNotification(forTabId: panelContext.workspace.id, surfaceId: panelContext.panelId)
            if hasUnread {
                panelContext.workspace.markPanelRead(panelContext.panelId)
            } else {
                panelContext.workspace.markPanelUnread(panelContext.panelId)
            }
        }
        registry.register(commandId: "palette.nextTabInPane") {
            tabManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            tabManager.selectPreviousSurface()
        }
        registry.register(commandId: "palette.openWorkspacePullRequests") {
            DispatchQueue.main.async {
                if !openWorkspacePullRequestsInConfiguredBrowser() {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.openDiffViewer") {
            if AppDelegate.shared?.openDiffViewerForFocusedWorkspace(for: tabManager) != true {
                NSSound.beep()
            }
        }

        registry.register(commandId: "palette.browserBack") {
            tabManager.focusedBrowserPanel?.goBack()
        }
        registry.register(commandId: "palette.browserForward") {
            tabManager.focusedBrowserPanel?.goForward()
        }
        registry.register(commandId: "palette.browserReload") {
            tabManager.focusedBrowserPanel?.reload()
        }
        registry.register(commandId: "palette.browserOpenDefault") {
            if !openFocusedBrowserInDefaultBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusAddressBar") {
            if !focusFocusedBrowserAddressBar() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusMode") {
            if !tabManager.toggleBrowserFocusModeForFocusedBrowser(reason: "commandPalette") {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleOmnibar") {
            if !tabManager.toggleOmnibarFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleDevTools") {
            if !tabManager.toggleDeveloperToolsFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserConsole") {
            if !tabManager.showJavaScriptConsoleFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserReactGrab") {
            if !tabManager.toggleReactGrabFromCurrentFocus() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomIn") {
            if !tabManager.zoomInFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomOut") {
            if !tabManager.zoomOutFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomReset") {
            if !tabManager.resetZoomFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.markdownZoomIn") {
            if !tabManager.zoomInFocusedMarkdown() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.markdownZoomOut") {
            if !tabManager.zoomOutFocusedMarkdown() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.markdownZoomReset") {
            if !tabManager.resetZoomFocusedMarkdown() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserClearHistory") {
            BrowserHistoryStore.shared.clearHistory()
        }
        registry.register(commandId: "palette.findInDirectory") {
            _ = AppDelegate.shared?.focusFileSearchInActiveMainWindow(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
        registry.register(commandId: "palette.browserSplitRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.browserSplitDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.browserDuplicateRight") {
            let url = tabManager.focusedBrowserPanel?.preferredURLStringForOmnibar().flatMap(URL.init(string:))
            _ = tabManager.createBrowserSplit(direction: .right, url: url)
        }

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            registry.register(commandId: target.commandPaletteCommandId) {
                if !openFocusedDirectory(in: target) {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.vscodeServeWebStop") {
            stopInlineVSCodeServeWeb()
        }
        registry.register(commandId: "palette.vscodeServeWebRestart") {
            if !restartInlineVSCodeServeWeb() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalFind") {
            tabManager.startSearch()
        }
        registry.register(commandId: "palette.terminalFindNext") {
            tabManager.findNext()
        }
        registry.register(commandId: "palette.terminalFindPrevious") {
            tabManager.findPrevious()
        }
        registry.register(commandId: "palette.terminalHideFind") {
            tabManager.hideFind()
        }
        registry.register(commandId: "palette.terminalUseSelectionForFind") {
            tabManager.searchSelection()
        }
        registry.register(commandId: "palette.terminalToggleTextBoxInput") {
            if !tabManager.toggleFocusedTerminalTextBox() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalFocusTextBoxInput") {
            if !tabManager.focusFocusedTerminalTextBoxInputOrTerminal() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalAttachTextBoxFile") {
            if !tabManager.attachFileToFocusedTerminalTextBoxInput() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalSendCtrlF") {
            if !tabManager.sendCtrlFToFocusedTerminal() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalSplitRight") {
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.splitRight.configID) {
                tabManager.createSplit(direction: .right)
            }
        }
        registry.register(commandId: "palette.forkAgentConversationRight") {
            forkFocusedAgentConversationRight()
        }
        registry.register(commandId: "palette.forkAgentConversationLeft") {
            forkFocusedAgentConversationLeft()
        }
        registry.register(commandId: "palette.forkAgentConversationTop") {
            forkFocusedAgentConversationTop()
        }
        registry.register(commandId: "palette.forkAgentConversationBottom") {
            forkFocusedAgentConversationBottom()
        }
        registry.register(commandId: "palette.forkAgentConversationNewTab") {
            forkFocusedAgentConversationToNewTab()
        }
        registry.register(commandId: "palette.forkAgentConversationNewWorkspace") {
            forkFocusedAgentConversationToNewWorkspace()
        }
        registry.register(commandId: "palette.terminalSplitDown") {
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.splitDown.configID) {
                tabManager.createSplit(direction: .down)
            }
        }
        registry.register(commandId: "palette.terminalSplitBrowserRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitBrowserDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.toggleSplitZoom") {
            if !tabManager.toggleFocusedSplitZoom() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.equalizeSplits") {
            if let workspace = tabManager.selectedWorkspace, !tabManager.equalizeSplits(tabId: workspace.id) {
#if DEBUG
                cmuxDebugLog("palette.equalizeSplits result=noSplitOrFailed workspaceId=\(workspace.id)")
#endif
            }
        }

        for issue in cmuxConfigStore.configurationIssues {
            let captured = issue
            registry.register(commandId: commandPaletteCmuxConfigIssueCommandID(issue)) {
                openCmuxConfigIssue(captured)
            }
        }
        for action in cmuxConfigStore.paletteCustomActions() {
            let captured = action
            registry.register(commandId: action.id) {
                executeConfiguredAction(captured)
            }
        }
    }

    private func openCmuxConfigIssue(_ issue: CmuxConfigIssue) {
        guard let sourcePath = issue.sourcePath,
              FileManager.default.fileExists(atPath: sourcePath) else {
            NSSound.beep()
            return
        }
        PreferredEditorSettings.open(URL(fileURLWithPath: sourcePath))
    }

    @discardableResult
    private func executeConfiguredAction(id: String) -> Bool {
        guard let action = cmuxConfigStore.resolvedAction(id: id) else {
            return false
        }
        return executeConfiguredAction(action)
    }

    @discardableResult
    private func executeConfiguredAction(_ action: CmuxResolvedConfigAction) -> Bool {
        let baseCwd = configuredActionBaseCwd()
        return CmuxConfigExecutor.execute(
            action: action,
            commands: cmuxConfigStore.loadedCommands,
            commandSourcePaths: cmuxConfigStore.commandSourcePaths,
            tabManager: tabManager,
            baseCwd: baseCwd,
            globalConfigPath: cmuxConfigStore.globalConfigPath
        )
    }

    private func configuredActionBaseCwd() -> String {
        tabManager.selectedWorkspace?.resolvedWorkingDirectory()
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

}
