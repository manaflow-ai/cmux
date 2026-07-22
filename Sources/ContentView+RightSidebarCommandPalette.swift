import AppKit
import CmuxCommandPalette
import CmuxSidebar
import CmuxSwiftRender

extension ContentView {
    static func commandPaletteShortcutAction(forCommandID commandId: String) -> KeyboardShortcutSettings.Action? {
        if let rightSidebarModeAction = commandPaletteRightSidebarModeShortcutAction(forCommandID: commandId) {
            return rightSidebarModeAction
        }

        switch commandId {
        case "palette.newWorkspace":
            return .newTab
        case "palette.newBrowserWorkspace":
            return .newBrowserWorkspace
        case "palette.newWindow":
            return .newWindow
        case "palette.openFolder":
            return .openFolder
        case "palette.reopenPreviousSession":
            return .reopenPreviousSession
        case "palette.reopenClosedBrowserTab":
            return .reopenClosedBrowserPanel
        case "palette.newTerminalTab":
            return .newSurface
        case "palette.newBrowserTab":
            return .openBrowser
        case "palette.closeWindow":
            return .closeWindow
        case "palette.toggleSidebar":
            return .toggleSidebar
        case "palette.showNotifications":
            return .showNotifications
        case "palette.jumpUnread":
            return .jumpToUnread
        case "palette.toggleUnread":
            return .toggleUnread
        case "palette.markOldestUnreadAndJumpNext":
            return .markOldestUnreadAndJumpNext
        case "palette.renameTab":
            return .renameTab
        case "palette.renameWorkspace":
            return .renameWorkspace
        case "palette.editWorkspaceDescription":
            return .editWorkspaceDescription
        case "palette.markWorkspaceDone":
            return .markWorkspaceDone
        case "palette.nextWorkspace":
            return .nextSidebarTab
        case "palette.previousWorkspace":
            return .prevSidebarTab
        case "palette.moveWorkspaceUp":
            return .moveWorkspaceUp
        case "palette.moveWorkspaceDown":
            return .moveWorkspaceDown
        case "palette.nextTabInPane":
            return .nextSurface
        case "palette.previousTabInPane":
            return .prevSurface
        case "palette.browserToggleDevTools":
            return .toggleBrowserDeveloperTools
        case "palette.browserConsole":
            return .showBrowserJavaScriptConsole
        case "palette.browserReactGrab":
            return .toggleReactGrab
        case "palette.browserSplitRight", "palette.terminalSplitBrowserRight":
            return .splitBrowserRight
        case "palette.browserSplitDown", "palette.terminalSplitBrowserDown":
            return .splitBrowserDown
        case "palette.terminalSplitRight":
            return .splitRight
        case "palette.terminalSplitDown":
            return .splitDown
        case "palette.findInDirectory":
            return .findInDirectory
        case "palette.terminalFind":
            return .find
        case "palette.terminalFindNext":
            return .findNext
        case "palette.terminalFindPrevious":
            return .findPrevious
        case "palette.terminalHideFind":
            return .hideFind
        case "palette.terminalUseSelectionForFind":
            return .useSelectionForFind
        case "palette.terminalFocusTextBoxInput":
            return .focusTextBoxInput
        case "palette.terminalAttachTextBoxFile":
            return .attachTextBoxFile
        case "palette.terminalSendCtrlF":
            return .sendCtrlFToTerminal
        case "palette.terminalClearScreenKeepScrollback":
            return .clearScreenKeepScrollback
        case "palette.toggleSplitZoom":
            return .toggleSplitZoom
        case "palette.equalizeSplits":
            return .equalizeSplits
        case "palette.triggerFlash":
            return .triggerFlash
        default:
            return nil
        }
    }

    static func commandPaletteRightSidebarModeCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return RightSidebarMode.availableModes().map { mode in
            let title = mode.shortcutAction?.label ?? mode.label
            return CommandPaletteCommandContribution(
                commandId: Self.commandPaletteRightSidebarModeCommandID(mode),
                title: constant(title),
                subtitle: constant(String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")),
                keywords: ["right", "sidebar", "show", "switch", "focus", mode.rawValue],
                arguments: commandPaletteOptionalFocusArguments,
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasPane)
                }
            )
        }
    }

    static func commandPaletteRightSidebarToolPaneCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return commandPaletteRightSidebarToolPaneCommandDescriptors().map { descriptor in
            CommandPaletteCommandContribution(
                commandId: descriptor.commandId,
                title: constant(descriptor.title),
                subtitle: constant(String(localized: "command.openRightSidebarToolAsPane.subtitle", defaultValue: "Pane")),
                keywords: ["open", "pane", "tool", "right", "sidebar", descriptor.mode.rawValue, descriptor.mode.label.lowercased()],
                arguments: commandPaletteOptionalFocusArguments,
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasPane)
                }
            )
        }
    }

    static func commandPaletteRightSidebarRejected(
        _ result: CmuxActionExecutionResult,
        invocation: CmuxActionInvocation,
        beep: @MainActor () -> Void
    ) -> CmuxActionExecutionResult {
        if invocation.source == .commandPalette {
            beep()
        }
        return result
    }

    static func commandPaletteRightSidebarShouldFocus(
        _ invocation: CmuxActionInvocation,
        targetIsSelected: Bool
    ) -> Bool {
        commandPaletteResolvedFocus(
            explicit: invocation.bool("focus"),
            source: invocation.source
        ) ?? targetIsSelected
    }

    static func commandPaletteRightSidebarModeCommandID(_ mode: RightSidebarMode) -> String {
        switch mode {
        case .files:
            return "palette.showRightSidebarFiles"
        case .find:
            return "palette.showRightSidebarFind"
        case .sessions:
            return "palette.showRightSidebarSessions"
        case .feed:
            return "palette.showRightSidebarFeed"
        case .dock:
            return "palette.showRightSidebarDock"
        case .customSidebar:
            return "palette.showRightSidebarCustomSidebar"
        }
    }

    static func commandPaletteRightSidebarToolPaneCommandDescriptors() -> [(mode: RightSidebarMode, commandId: String, title: String)] {
        RightSidebarMode.paneModes.compactMap { mode in
            guard let commandId = commandPaletteRightSidebarToolPaneCommandID(mode),
                  let title = commandPaletteRightSidebarToolPaneTitle(mode) else {
                return nil
            }
            return (mode: mode, commandId: commandId, title: title)
        }
    }

    private static func commandPaletteRightSidebarToolPaneCommandID(_ mode: RightSidebarMode) -> String? {
        switch mode {
        case .files:
            return "palette.openFilesPane"
        case .find:
            return "palette.openFindPane"
        case .sessions:
            return "palette.openVaultPane"
        case .feed, .dock, .customSidebar:
            return nil
        }
    }

    private static func commandPaletteRightSidebarToolPaneTitle(_ mode: RightSidebarMode) -> String? {
        switch mode {
        case .files:
            return String(localized: "command.openFilesPane.title", defaultValue: "Open Files as Pane")
        case .find:
            return String(localized: "command.openFindPane.title", defaultValue: "Open Find as Pane")
        case .sessions:
            return String(localized: "command.openVaultPane.title", defaultValue: "Open Vault as Pane")
        case .feed, .dock, .customSidebar:
            return nil
        }
    }

    func handleCommandPaletteRightSidebarMode(
        _ mode: RightSidebarMode,
        targetWindow: NSWindow?,
        invocation: CmuxActionInvocation,
        focus: Bool = true,
        sourceWorkspaceID: UUID? = nil,
        sourcePanelID: UUID? = nil,
        beep: @MainActor () -> Void = { NSSound.beep() }
    ) -> CmuxActionExecutionResult {
        guard mode.isAvailable() else {
            return Self.commandPaletteRightSidebarRejected(
                .targetUnavailable,
                invocation: invocation,
                beep: beep
            )
        }
        guard let targetWindow else {
            return Self.commandPaletteRightSidebarRejected(
                .targetUnavailable,
                invocation: invocation,
                beep: beep
            )
        }
        if AppDelegate.shared?.presentRightSidebarInActiveMainWindow(
            mode: mode,
            focus: focus,
            focusFirstItem: true,
            preferredWindow: targetWindow,
            sourceWorkspaceID: sourceWorkspaceID,
            sourcePanelID: sourcePanelID
        ) != true {
            guard sourceWorkspaceID == nil, sourcePanelID == nil else {
                return Self.commandPaletteRightSidebarRejected(
                    .targetUnavailable,
                    invocation: invocation,
                    beep: beep
                )
            }
            fileExplorerState.setVisible(true)
            if fileExplorerState.mode != mode {
                fileExplorerState.mode = mode
            }
        }
        return .presented
    }

    func handleCommandPaletteRightSidebarMode(
        _ mode: RightSidebarMode,
        context: CommandPaletteActionContext,
        invocation: CmuxActionInvocation,
        beep: @MainActor () -> Void = { NSSound.beep() }
    ) -> CmuxActionExecutionResult {
        guard context.target.windowID == windowId,
              let (workspace, panelID, _) = context.panel() else {
            return Self.commandPaletteRightSidebarRejected(
                .targetUnavailable,
                invocation: invocation,
                beep: beep
            )
        }
        let focus = Self.commandPaletteRightSidebarShouldFocus(
            invocation,
            targetIsSelected: context.tabManager.selectedTabId == workspace.id
        )
        return handleCommandPaletteRightSidebarMode(
            mode,
            targetWindow: AppDelegate.shared?.mainWindow(for: context.target.windowID),
            invocation: invocation,
            focus: focus,
            sourceWorkspaceID: workspace.id,
            sourcePanelID: panelID,
            beep: beep
        )
    }

    func handleCommandPaletteRightSidebarToolPane(
        _ mode: RightSidebarMode,
        context: CommandPaletteActionContext,
        invocation: CmuxActionInvocation,
        beep: @MainActor () -> Void = { NSSound.beep() }
    ) -> CmuxActionExecutionResult {
        guard mode.canOpenAsPane,
              let (workspace, panelID, _) = context.panel(),
              let paneID = workspace.paneId(forPanelId: panelID) else {
            return Self.commandPaletteRightSidebarRejected(
                .targetUnavailable,
                invocation: invocation,
                beep: beep
            )
        }

        let focus = Self.commandPaletteRightSidebarShouldFocus(
            invocation,
            targetIsSelected: context.tabManager.selectedTabId == workspace.id
        )
        sidebarSelectionState.selection = .tabs
        workspace.clearSplitZoom()
        guard workspace.openOrFocusRightSidebarToolSurface(
            inPane: paneID,
            mode: mode,
            focus: focus,
            sourcePanelID: panelID
        ) != nil else {
            return Self.commandPaletteRightSidebarRejected(
                .targetUnavailable,
                invocation: invocation,
                beep: beep
            )
        }
        return .completed
    }

    func openCustomSidebarPane(_ name: String) {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }

        sidebarSelectionState.selection = .tabs
        workspace.clearSplitZoom()
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.openOrFocusCustomSidebarSplit(from: focusedPanelId, name: name) != nil {
            return
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              workspace.openOrFocusCustomSidebarSurface(inPane: paneId, name: name, focus: true) != nil else {
            NSSound.beep()
            return
        }
    }

    private static func commandPaletteRightSidebarModeShortcutAction(
        forCommandID commandID: String
    ) -> KeyboardShortcutSettings.Action? {
        guard let mode = RightSidebarMode.availableModes().first(where: { mode in
            Self.commandPaletteRightSidebarModeCommandID(mode) == commandID
        }) else {
            return nil
        }
        return mode.shortcutAction
    }

    func rightSidebarCustomSidebarDataContext(now: Date) -> [String: SwiftValue] {
        let selectedId = tabManager.selectedTabId
        let workspaces = tabManager.tabs.enumerated().map { index, workspace in
            workspace.customSidebarWorkspaceSnapshot(
                index: index,
                selectedId: selectedId,
                unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id)
            )
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedId }
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: workspaces,
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? "",
            totalUnreadCount: sidebarUnread.totalUnreadCount,
            now: now
        )
        return CustomSidebarDataContextBuilder().dataContext(for: snapshot)
    }

}

extension TabManager {
    /// Resolves the content/action target for this window's right sidebar.
    ///
    /// An explicit automation binding is authoritative: a stale workspace or
    /// panel returns nil and never falls back to the user's current selection.
    /// Without a binding, ordinary UI behavior follows the selected workspace.
    func rightSidebarContentTarget(
        explicitWorkspaceID: UUID?,
        explicitPanelID: UUID?
    ) -> (workspace: Workspace, panelID: UUID?)? {
        if let explicitWorkspaceID {
            guard let workspace = tabs.first(where: { $0.id == explicitWorkspaceID }) else {
                return nil
            }
            if let explicitPanelID, workspace.panels[explicitPanelID] == nil {
                return nil
            }
            return (workspace, explicitPanelID)
        }

        guard explicitPanelID == nil,
              let selectedWorkspaceID = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedWorkspaceID }) else {
            return nil
        }
        return (workspace, nil)
    }
}
