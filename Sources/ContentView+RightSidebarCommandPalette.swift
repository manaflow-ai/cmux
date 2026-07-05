import AppKit
import CmuxCommandPalette
import CmuxInbox
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
        case "palette.nextWorkspace":
            return .nextSidebarTab
        case "palette.previousWorkspace":
            return .prevSidebarTab
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
                keywords: ["right", "sidebar", "show", "switch", "focus", mode.rawValue]
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
                keywords: ["open", "pane", "tool", "right", "sidebar", descriptor.mode.rawValue, descriptor.mode.label.lowercased()]
            )
        }
    }

    static func commandPaletteInboxCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: "palette.openInbox",
                title: constant(String(localized: "command.inbox.open.title", defaultValue: "Open Inbox")),
                subtitle: constant(String(localized: "command.inbox.subtitle", defaultValue: "Inbox")),
                keywords: ["inbox", "integrations", "messages", "attention", "gmail", "slack", "discord", "imessage", "agent"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.inbox.unreadSlack",
                title: constant(String(localized: "command.inbox.unreadSlack.title", defaultValue: "Unread Slack")),
                subtitle: constant(String(localized: "command.inbox.subtitle", defaultValue: "Inbox")),
                keywords: ["inbox", "unread", "slack", "messages"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.inbox.unreadGmail",
                title: constant(String(localized: "command.inbox.unreadGmail.title", defaultValue: "Unread Gmail")),
                subtitle: constant(String(localized: "command.inbox.subtitle", defaultValue: "Inbox")),
                keywords: ["inbox", "unread", "gmail", "email", "mail"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.inbox.draftReply",
                title: constant(String(localized: "command.inbox.draftReply.title", defaultValue: "Draft Reply")),
                subtitle: constant(String(localized: "command.inbox.subtitle", defaultValue: "Inbox")),
                keywords: ["inbox", "draft", "reply", "send", "approve"]
            ),
        ]
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

    func handleCommandPaletteRightSidebarMode(_ mode: RightSidebarMode, observedWindow: NSWindow?) {
        guard mode.isAvailable() else {
            NSSound.beep()
            return
        }
        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: true,
            preferredWindow: observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        ) != true {
            fileExplorerState.setVisible(true)
            if fileExplorerState.mode != mode {
                fileExplorerState.mode = mode
            }
        }
    }

    func handleCommandPaletteRightSidebarToolPane(_ mode: RightSidebarMode) {
        openRightSidebarToolPane(mode)
    }

    func registerInboxCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        observedWindow: NSWindow?
    ) {
        registry.register(commandId: "palette.openInbox") {
            InboxRuntimeRegistry.current?.setSource(nil)
            handleCommandPaletteRightSidebarMode(.feed, observedWindow: observedWindow)
        }
        registry.register(commandId: "palette.inbox.unreadSlack") {
            InboxRuntimeRegistry.current?.setFilter(.unread)
            InboxRuntimeRegistry.current?.setSource(.slack)
            handleCommandPaletteRightSidebarMode(.feed, observedWindow: observedWindow)
        }
        registry.register(commandId: "palette.inbox.unreadGmail") {
            InboxRuntimeRegistry.current?.setFilter(.unread)
            InboxRuntimeRegistry.current?.setSource(.gmail)
            handleCommandPaletteRightSidebarMode(.feed, observedWindow: observedWindow)
        }
        registry.register(commandId: "palette.inbox.draftReply") {
            guard let runtime = InboxRuntimeRegistry.current,
                  let threadID = runtime.selectedThread?.threadID else {
                NSSound.beep()
                return
            }
            runtime.draftReply(threadID: threadID, instruction: nil)
            handleCommandPaletteRightSidebarMode(.feed, observedWindow: observedWindow)
        }
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
            rightSidebarCustomSidebarWorkspaceSnapshot(workspace, index: index, selectedId: selectedId)
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

    private func rightSidebarCustomSidebarWorkspaceSnapshot(
        _ workspace: Workspace,
        index: Int,
        selectedId: UUID?
    ) -> CustomSidebarWorkspaceSnapshot {
        let focusedPanelId = workspace.focusedPanelId
        let firstBranch = workspace.sidebarGitBranchesInDisplayOrder().first
        let progress = workspace.progress.map {
            CustomSidebarWorkspaceSnapshot.Progress(value: $0.value, label: $0.label)
        }
        let remote = workspace.remoteDisplayTarget.map { target in
            CustomSidebarWorkspaceSnapshot.Remote(
                target: target,
                stateRawValue: workspace.remoteConnectionState.rawValue,
                isConnected: workspace.remoteConnectionState == .connected
            )
        }
        return CustomSidebarWorkspaceSnapshot(
            id: workspace.id,
            title: workspace.customTitle ?? workspace.title,
            isSelected: workspace.id == selectedId,
            isPinned: workspace.isPinned,
            index: index,
            directory: workspace.currentDirectory,
            listeningPorts: workspace.listeningPorts,
            unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id),
            surfaces: rightSidebarCustomSidebarSurfaceSnapshots(workspace, focusedPanelId: focusedPanelId),
            surfaceCount: workspace.bonsplitController.allPaneIds.reduce(0) { $0 + workspace.bonsplitController.tabs(inPane: $1).count },
            customDescription: workspace.customDescription,
            customColor: workspace.customColor,
            gitBranch: firstBranch?.branch,
            gitIsDirty: firstBranch?.isDirty ?? false,
            pullRequestValues: workspace.customSidebarPullRequestValues(),
            progress: progress,
            latestConversationMessage: workspace.latestConversationMessage,
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            remote: remote
        )
    }

    private func rightSidebarCustomSidebarSurfaceSnapshots(
        _ workspace: Workspace,
        focusedPanelId: UUID?
    ) -> [CustomSidebarSurfaceSnapshot] {
        var surfaces: [CustomSidebarSurfaceSnapshot] = []
        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                let git = workspace.panelGitBranches[panelId]
                surfaces.append(
                    CustomSidebarSurfaceSnapshot(
                        panelId: panelId,
                        title: tab.title,
                        isFocused: panelId == focusedPanelId,
                        isPinned: workspace.pinnedPanelIds.contains(panelId),
                        directory: workspace.panelDirectories[panelId],
                        gitBranch: git?.branch,
                        gitIsDirty: git?.isDirty ?? false,
                        listeningPorts: workspace.surfaceListeningPorts[panelId] ?? []
                    )
                )
            }
        }
        return surfaces
    }
}
