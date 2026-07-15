import AppKit
import Foundation

extension AppDelegate {
    func executeConfiguredCmuxAction(
        _ action: CmuxResolvedConfigAction,
        context: MainWindowContext,
        preferredWindow: NSWindow? = nil,
        onExecuted: (() -> Void)? = nil,
        onCloudVMCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = nil
    ) -> Bool {
        switch action.action {
        case .builtIn(let builtIn):
            switch builtIn {
            case .newWorkspace:
                context.tabManager.addWorkspace()
                onExecuted?()
                return true
            case .newAgentChat: return performConfiguredNewAgentChatAction(context: context, preferredWindow: preferredWindow, onExecuted: onExecuted)
            case .cloudVM:
                let didStart = performCloudVMAction(
                    tabManager: context.tabManager,
                    preferredWindow: resolvedWindow(for: context) ?? preferredWindow,
                    debugSource: "configured.cmux.cloudvm",
                    onCompletion: onCloudVMCompletion
                )
                if didStart { onExecuted?() }
                return didStart
            case .mobileConnect:
                MobilePairingWindowController.shared.show()
                onExecuted?()
                return true
            case .newTerminal:
                context.tabManager.newSurface()
                onExecuted?()
                return true
            case .newBrowser:
                let previousTabManager = tabManager
                tabManager = context.tabManager
                defer { tabManager = previousTabManager }
                guard openBrowserAndFocusAddressBar(insertAtEnd: true) != nil else {
                    return false
                }
                onExecuted?()
                return true
            case .newNote:
#if DEBUG
                if let debugNewNoteBuiltInActionHandler {
                    debugNewNoteBuiltInActionHandler()
                    onExecuted?()
                    return true
                }
#endif
                guard let workspace = context.tabManager.selectedWorkspace,
                      let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
                    return false
                }
                let panelId = workspace.focusedPanelId
                    ?? workspace.bonsplitController.selectedTab(inPane: paneId).flatMap { workspace.panelIdFromSurfaceId($0.id) }
                Task { @MainActor in
                    if let panelId, workspace.panels[panelId] != nil {
                        _ = await workspace.openAttachedNoteForSurface(
                            inPane: paneId,
                            panelId: panelId,
                            focus: true
                        )
                    } else {
                        _ = await workspace.openAttachedNoteForWorkspace(inPane: paneId, focus: true)
                    }
                }
                onExecuted?()
                return true
            case .splitRight:
                if shouldSuppressSplitShortcutForTransientTerminalFocusState(
                    direction: .right,
                    tabManager: context.tabManager
                ) {
                    return true
                }
                let didSplit = performSplitShortcut(
                    direction: .right,
                    preferredWindow: preferredWindow ?? shortcutRoutingActiveWindow
                )
                if didSplit { onExecuted?() }
                return didSplit
            case .splitDown:
                if shouldSuppressSplitShortcutForTransientTerminalFocusState(
                    direction: .down,
                    tabManager: context.tabManager
                ) {
                    return true
                }
                let didSplit = performSplitShortcut(
                    direction: .down,
                    preferredWindow: preferredWindow ?? shortcutRoutingActiveWindow
                )
                if didSplit { onExecuted?() }
                return didSplit
            case .more:
                return false
            case .rightSidebarFiles:
                let didFocus = focusRightSidebarInActiveMainWindow(
                    mode: .files,
                    focusFirstItem: true,
                    preferredWindow: preferredWindow
                )
                if didFocus { onExecuted?() }
                return didFocus
            case .rightSidebarNotes:
                guard RightSidebarMode.notes.isAvailable() else { return false }
                let didFocus = focusRightSidebarInActiveMainWindow(
                    mode: .notes,
                    focusFirstItem: true,
                    preferredWindow: preferredWindow
                )
                if didFocus { onExecuted?() }
                return didFocus
            case .rightSidebarFind:
                let didFocus = focusRightSidebarInActiveMainWindow(
                    mode: .find,
                    focusFirstItem: true,
                    preferredWindow: preferredWindow
                )
                if didFocus { onExecuted?() }
                return didFocus
            case .rightSidebarVault:
                let didFocus = focusRightSidebarInActiveMainWindow(
                    mode: .sessions,
                    focusFirstItem: true,
                    preferredWindow: preferredWindow
                )
                if didFocus { onExecuted?() }
                return didFocus
            case .rightSidebarFeed:
                guard RightSidebarMode.feed.isAvailable() else { return false }
                let didFocus = focusRightSidebarInActiveMainWindow(
                    mode: .feed,
                    focusFirstItem: true,
                    preferredWindow: preferredWindow
                )
                if didFocus { onExecuted?() }
                return didFocus
            case .rightSidebarDock:
                guard RightSidebarMode.dock.isAvailable() else { return false }
                let didFocus = focusRightSidebarInActiveMainWindow(
                    mode: .dock,
                    focusFirstItem: true,
                    preferredWindow: preferredWindow
                )
                if didFocus { onExecuted?() }
                return didFocus
            case .filesPane:
                let didOpen = openRightSidebarToolPane(mode: .files, context: context)
                if didOpen { onExecuted?() }
                return didOpen
            case .findPane:
                let didOpen = openRightSidebarToolPane(mode: .find, context: context)
                if didOpen { onExecuted?() }
                return didOpen
            case .vaultPane:
                let didOpen = openRightSidebarToolPane(mode: .sessions, context: context)
                if didOpen { onExecuted?() }
                return didOpen
            case .diffViewer:
                // One shared opener for every Diff Viewer entrypoint: the
                // agent-aware path (last-turn baseline, coalesced context
                // reads), not a parallel plain `--unstaged` launch.
                let didOpen = openDiffViewerForFocusedWorkspace(for: context.tabManager)
                if didOpen { onExecuted?() }
                return didOpen
            case .revealCurrentDirectoryInFinder:
                guard let workspace = context.tabManager.selectedWorkspace,
                      let path = WorkspaceFinderDirectoryResolver.path(for: workspace) else {
                    return false
                }
                Task {
                    await WorkspaceFinderDirectoryOpener.openInFinder(URL(fileURLWithPath: path, isDirectory: true))
                }
                onExecuted?()
                return true
            case .customizeSurfaceTabBar:
                openPreferencesWindow(
                    debugSource: "configured.cmux.customizeSurfaceTabBar",
                    navigationTarget: .paneTabBar
                )
                onExecuted?()
                return true
            }
        case .command, .agent, .workspaceCommand, .workspace:
            guard let cmuxConfigStore = context.cmuxConfigStore else {
                return false
            }
            let rawCwd = context.tabManager.selectedWorkspace?.currentDirectory
            let baseCwd = (rawCwd?.isEmpty == false) ? rawCwd!
                : FileManager.default.homeDirectoryForCurrentUser.path
            return CmuxConfigExecutor.execute(
                action: action,
                commands: cmuxConfigStore.loadedCommands,
                commandSourcePaths: cmuxConfigStore.commandSourcePaths,
                tabManager: context.tabManager,
                baseCwd: baseCwd,
                globalConfigPath: cmuxConfigStore.globalConfigPath,
                presentingWindow: preferredWindow,
                onExecuted: onExecuted
            )
        case .actionReference:
            return false
        }
    }

    private func openRightSidebarToolPane(mode: RightSidebarMode, context: MainWindowContext) -> Bool {
        guard mode.canOpenAsPane,
              let workspace = context.tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }
        workspace.clearSplitZoom()
        return workspace.openOrFocusRightSidebarToolSurface(inPane: paneId, mode: mode, focus: true) != nil
    }

}
