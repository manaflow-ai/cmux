import AppKit

extension ContentView {
    static func commandPaletteShortcutAction(forCommandID commandId: String) -> KeyboardShortcutSettings.Action? {
        if let rightSidebarModeAction = commandPaletteRightSidebarModeShortcutAction(forCommandID: commandId) {
            return rightSidebarModeAction
        }

        switch commandId {
        case "palette.newWorkspace":
            return .newTab
        case "palette.newWindow":
            return .newWindow
        case "palette.openFolder":
            return .openFolder
        case "palette.reopenPreviousSession":
            return .reopenPreviousSession
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
            CommandPaletteCommandContribution(
                commandId: Self.commandPaletteRightSidebarModeCommandID(mode),
                title: constant(mode.shortcutAction.label),
                subtitle: constant(String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")),
                keywords: ["right", "sidebar", "show", "switch", "focus", mode.rawValue]
            )
        }
    }

    static func commandPaletteRightSidebarToolPaneCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return RightSidebarMode.paneModes.map { mode in
            CommandPaletteCommandContribution(
                commandId: Self.commandPaletteRightSidebarToolPaneCommandID(mode),
                title: constant(commandPaletteRightSidebarToolPaneTitle(mode)),
                subtitle: constant(String(localized: "command.openRightSidebarToolAsPane.subtitle", defaultValue: "Pane")),
                keywords: ["open", "pane", "tool", "right", "sidebar", mode.rawValue, mode.label.lowercased()]
            )
        }
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
        }
    }

    static func commandPaletteRightSidebarToolPaneCommandID(_ mode: RightSidebarMode) -> String {
        switch mode {
        case .files:
            return "palette.openFilesPane"
        case .find:
            return "palette.openFindPane"
        case .sessions:
            return "palette.openVaultPane"
        case .feed:
            return "palette.openFeedPane"
        case .dock:
            return "palette.openDockPane"
        }
    }

    static func commandPaletteRightSidebarToolPaneTitle(_ mode: RightSidebarMode) -> String {
        switch mode {
        case .files:
            return String(localized: "command.openFilesPane.title", defaultValue: "Open Files as Pane")
        case .find:
            return String(localized: "command.openFindPane.title", defaultValue: "Open Find as Pane")
        case .sessions:
            return String(localized: "command.openVaultPane.title", defaultValue: "Open Vault as Pane")
        case .feed:
            return String(localized: "command.openFeedPane.title", defaultValue: "Open Feed as Pane")
        case .dock:
            return String(localized: "command.openDockPane.title", defaultValue: "Open Dock as Pane")
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

    private static func commandPaletteRightSidebarModeShortcutAction(
        forCommandID commandID: String
    ) -> KeyboardShortcutSettings.Action? {
        RightSidebarMode.availableModes().first { mode in
            Self.commandPaletteRightSidebarModeCommandID(mode) == commandID
        }?.shortcutAction
    }
}
