import CmuxCommandPalette
import AppKit

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
        CommandPaletteRightSidebarContributionProvider().buildModeContributions(
            commands: RightSidebarMode.availableModes().map { mode in
                CommandPaletteRightSidebarContributionProvider.ModeCommand(
                    mode: mode,
                    title: mode.shortcutAction?.label ?? mode.label
                )
            },
            subtitle: String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")
        )
    }

    static func commandPaletteRightSidebarToolPaneCommandContributions() -> [CommandPaletteCommandContribution] {
        CommandPaletteRightSidebarContributionProvider().buildToolPaneContributions(
            commands: commandPaletteRightSidebarToolPaneCommandDescriptors().map { descriptor in
                CommandPaletteRightSidebarContributionProvider.ToolPaneCommand(
                    mode: descriptor.mode,
                    title: descriptor.title,
                    labelKeyword: descriptor.mode.label.lowercased()
                )
            },
            subtitle: String(localized: "command.openRightSidebarToolAsPane.subtitle", defaultValue: "Pane")
        )
    }

    static func commandPaletteRightSidebarModeCommandID(_ mode: RightSidebarMode) -> String {
        CommandPaletteRightSidebarContributionProvider().modeCommandID(mode)
    }

    static func commandPaletteRightSidebarToolPaneCommandDescriptors() -> [(mode: RightSidebarMode, commandId: String, title: String)] {
        let provider = CommandPaletteRightSidebarContributionProvider()
        return RightSidebarMode.paneModes.compactMap { mode in
            guard let commandId = provider.toolPaneCommandID(mode),
                  let title = commandPaletteRightSidebarToolPaneTitle(mode) else {
                return nil
            }
            return (mode: mode, commandId: commandId, title: title)
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
        case .feed, .dock:
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

    private static func commandPaletteRightSidebarModeShortcutAction(
        forCommandID commandID: String
    ) -> KeyboardShortcutSettings.Action? {
        let provider = CommandPaletteRightSidebarContributionProvider()
        guard let mode = RightSidebarMode.availableModes().first(where: { mode in
            provider.modeCommandID(mode) == commandID
        }) else {
            return nil
        }
        return mode.shortcutAction
    }
}
