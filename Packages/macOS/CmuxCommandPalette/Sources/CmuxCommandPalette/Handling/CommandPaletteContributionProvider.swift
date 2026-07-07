import Foundation

/// Owns the static command-palette contribution catalog: the command
/// identifiers, search keywords, `when`/`enablement` predicates over
/// ``CommandPaletteContextSnapshot`` keys, and the *order* in which built-in
/// commands and host-supplied blocks interleave.
///
/// The provider deliberately holds no localized literals. Display text resolves
/// against the app bundle (see ``CommandPaletteContributionStrings``), and the
/// dynamic, app-state-dependent slices arrive through
/// ``CommandPaletteContributionHostBlocks``. ``build(strings:hostBlocks:)``
/// reproduces the exact ordinal sequence the legacy `ContentView` builder used,
/// so the assembled list is byte-faithful and the downstream `when`/`enablement`
/// filtering is unchanged.
///
/// Runnable handlers are registered separately through
/// ``CommandPaletteActionHandling``; this type covers declarations only.
public struct CommandPaletteContributionProvider {
    /// Creates the provider. It is stateless; the catalog is data baked into
    /// ``build(strings:hostBlocks:)``.
    public init() {}

    /// Assembles the full ordered contribution catalog.
    ///
    /// - Parameters:
    ///   - strings: App-resolved titles and subtitles for the built-in commands.
    ///   - hostBlocks: App-supplied dynamic slices interleaved at their legacy
    ///     ordinal positions.
    /// - Returns: The contributions in the exact order the palette expects,
    ///   before any `when`/`enablement` filtering.
    public func build(
        strings: CommandPaletteContributionStrings,
        hostBlocks: CommandPaletteContributionHostBlocks
    ) -> [CommandPaletteCommandContribution] {
        let subtitleStrings = strings.subtitle

        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        func workspaceSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            if let name = context.string(CommandPaletteContextKeys.workspaceName) {
                return subtitleStrings.workspaceNamed(name)
            }
            return subtitleStrings.workspaceFallback
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            if let name = context.string(CommandPaletteContextKeys.panelName) {
                return subtitleStrings.panelNamed(name)
            }
            return subtitleStrings.panelFallback
        }

        func browserPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            if let name = context.string(CommandPaletteContextKeys.panelName) {
                return subtitleStrings.browserNamed(name)
            }
            return subtitleStrings.browserFallback
        }

        func terminalPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            if let name = context.string(CommandPaletteContextKeys.panelName) {
                return subtitleStrings.terminalNamed(name)
            }
            return subtitleStrings.terminalFallback
        }

        func markdownPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            if let name = context.string(CommandPaletteContextKeys.panelName) {
                return subtitleStrings.markdownNamed(name)
            }
            return subtitleStrings.markdownFallback
        }

        let global = strings.global
        let layout = strings.layout
        let notifications = strings.notifications
        let updates = strings.updates
        let workspace = strings.workspace
        let tab = strings.tab
        let browser = strings.browser
        let markdown = strings.markdown
        let terminal = strings.terminal
        let fork = strings.fork
        let split = strings.split

        var contributions: [CommandPaletteCommandContribution] = []

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                title: constant(global.newWorkspaceTitle),
                subtitle: constant(global.newWorkspaceSubtitle),
                keywords: ["create", "new", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserWorkspace",
                title: constant(global.newBrowserWorkspaceTitle),
                subtitle: constant(global.newBrowserWorkspaceSubtitle),
                keywords: ["create", "new", "browser", "workspace", "web"],
                when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWindow",
                title: constant(global.newWindowTitle),
                subtitle: constant(global.newWindowSubtitle),
                keywords: ["create", "new", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.installCLI",
                title: constant(global.installCLITitle),
                subtitle: constant(global.installCLISubtitle),
                keywords: ["install", "cli", "path", "shell", "command", "symlink"],
                when: { !$0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.uninstallCLI",
                title: constant(global.uninstallCLITitle),
                subtitle: constant(global.uninstallCLISubtitle),
                keywords: ["uninstall", "remove", "cli", "path", "shell", "command", "symlink"],
                when: { $0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolder",
                title: constant(global.openFolderTitle),
                subtitle: constant(global.openFolderSubtitle),
                keywords: ["open", "folder", "repository", "project", "directory"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolderInVSCodeInline",
                title: constant(global.openFolderInVSCodeInlineTitle),
                subtitle: constant(global.openFolderInVSCodeInlineSubtitle),
                keywords: ["open", "folder", "directory", "project", "vs", "code", "inline", "editor", "browser"],
                when: { _ in hostBlocks.vscodeInlineAvailable() }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenPreviousSession",
                title: constant(global.reopenPreviousSessionTitle),
                subtitle: constant(global.reopenPreviousSessionSubtitle),
                keywords: ["reopen", "restore", "previous", "session", "launch", "resume"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalTab",
                title: constant(layout.newTerminalTabTitle),
                subtitle: constant(layout.newTerminalTabSubtitle),
                shortcutHint: "⌘T",
                keywords: ["new", "terminal", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserTab",
                title: constant(layout.newBrowserTabTitle),
                subtitle: constant(layout.newBrowserTabSubtitle),
                shortcutHint: "⌘⇧L",
                keywords: ["new", "browser", "tab", "web"],
                when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeTab",
                title: constant(layout.closeTabTitle),
                subtitle: constant(layout.closeTabSubtitle),
                shortcutHint: "⌘W",
                keywords: ["close", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspace",
                title: constant(layout.closeWorkspaceTitle),
                subtitle: constant(layout.closeWorkspaceSubtitle),
                shortcutHint: "⌘⇧W",
                keywords: ["close", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWindow",
                title: constant(layout.closeWindowTitle),
                subtitle: constant(layout.closeWindowSubtitle),
                keywords: ["close", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleFullScreen",
                title: constant(layout.toggleFullScreenTitle),
                subtitle: constant(layout.toggleFullScreenSubtitle),
                keywords: ["fullscreen", "full", "screen", "window", "toggle"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenClosedBrowserTab",
                title: constant(global.reopenClosedBrowserTabTitle),
                subtitle: constant(global.reopenClosedBrowserTabSubtitle),
                keywords: ["reopen", "closed", "recently", "history", "tab", "workspace", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSidebar",
                title: constant(layout.toggleSidebarTitle),
                subtitle: constant(layout.toggleSidebarSubtitle),
                keywords: ["toggle", "sidebar", "left", "layout"]
            )
        )
        // "Sidebar: <provider>" switch commands for each available view, built
        // app-side because they read the hosted extension sidebar descriptors.
        contributions.append(contentsOf: hostBlocks.extensionSidebar)
        contributions.append(contentsOf: hostBlocks.rightSidebarMode)
        contributions.append(contentsOf: hostBlocks.rightSidebarToolPane)
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleMatchTerminalBackground",
                title: { context in
                    context.bool(CommandPaletteContextKeys.sidebarMatchTerminalBackground)
                        ? layout.disableMatchTerminalBackgroundTitle
                        : layout.enableMatchTerminalBackgroundTitle
                },
                subtitle: constant(layout.matchTerminalBackgroundSubtitle),
                keywords: ["match", "terminal", "background", "transparency", "sidebar", "surface", "chrome"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableMinimalMode",
                title: constant(layout.enableMinimalModeTitle),
                subtitle: constant(layout.toggleSidebarSubtitle),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { !$0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableMinimalMode",
                title: constant(layout.disableMinimalModeTitle),
                subtitle: constant(layout.toggleSidebarSubtitle),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(contentsOf: hostBlocks.view)
        contributions.append(contentsOf: hostBlocks.canvas)
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.showNotifications",
                title: constant(notifications.showNotificationsTitle),
                subtitle: constant(notifications.showNotificationsSubtitle),
                keywords: ["notifications", "inbox"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpUnread",
                title: constant(notifications.jumpUnreadTitle),
                subtitle: constant(notifications.jumpUnreadSubtitle),
                keywords: ["jump", "unread", "notification"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleUnread",
                title: constant(notifications.toggleUnreadTitle),
                subtitle: constant(notifications.jumpUnreadSubtitle),
                keywords: ["toggle", "mark", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markOldestUnreadAndJumpNext",
                title: constant(notifications.markOldestUnreadAndJumpNextTitle),
                subtitle: constant(notifications.jumpUnreadSubtitle),
                keywords: ["mark", "oldest", "unread", "jump", "next", "notification", "defer"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openSettings",
                title: constant(global.openSettingsTitle),
                subtitle: constant(global.openSettingsSubtitle),
                shortcutHint: "⌘,",
                keywords: ["settings", "preferences"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openCmuxSettingsFile",
                title: constant(global.openCmuxSettingsFileTitle),
                subtitle: constant(global.openCmuxSettingsFileSubtitle),
                keywords: ["open", "cmux", "json", "config", "configuration", "settings", "file", "editor", "dotfile"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openGhosttySettings",
                title: constant(global.openGhosttySettingsTitle),
                subtitle: constant(global.openGhosttySettingsSubtitle),
                keywords: ["open", "ghostty", "settings", "config", "configuration", "file", "textedit", "terminal"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.mobileConnect",
                title: constant(global.mobileConnectTitle),
                subtitle: constant(global.mobileConnectSubtitle),
                keywords: hostBlocks.mobileConnectKeywords
            )
        )
        contributions.append(contentsOf: hostBlocks.auth)
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.makeDefaultTerminal",
                title: constant(global.makeDefaultTerminalTitle),
                subtitle: constant(global.makeDefaultTerminalSubtitle),
                keywords: hostBlocks.makeDefaultTerminalKeywords,
                when: { !$0.bool(CommandPaletteContextKeys.defaultTerminalIsDefault) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.checkForUpdates",
                title: constant(updates.checkForUpdatesTitle),
                subtitle: constant(updates.checkForUpdatesSubtitle),
                keywords: ["update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.applyUpdateIfAvailable",
                title: constant(updates.applyUpdateIfAvailableTitle),
                subtitle: constant(updates.applyUpdateIfAvailableSubtitle),
                keywords: ["apply", "install", "update", "available"],
                when: { $0.bool(CommandPaletteContextKeys.updateHasAvailable) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.attemptUpdate",
                title: constant(updates.attemptUpdateTitle),
                subtitle: constant(updates.attemptUpdateSubtitle),
                keywords: ["attempt", "check", "update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.restartSocketListener",
                title: constant(global.restartSocketListenerTitle),
                subtitle: constant(global.restartSocketListenerSubtitle),
                keywords: ["restart", "socket", "listener", "cli", "cmux", "control"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableBrowser",
                title: constant(global.disableBrowserTitle),
                subtitle: constant(global.disableBrowserSubtitle),
                keywords: ["browser", "disable", "external", "default", "open", "auth"],
                when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableBrowser",
                title: constant(global.enableBrowserTitle),
                subtitle: constant(global.enableBrowserSubtitle),
                keywords: ["browser", "enable", "embedded", "open"],
                when: { $0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(contentsOf: hostBlocks.settingsToggle)

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameWorkspace",
                title: constant(workspace.renameTitle),
                subtitle: workspaceSubtitle,
                keywords: ["rename", "workspace", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.editWorkspaceDescription",
                title: constant(workspace.editDescriptionTitle),
                subtitle: workspaceSubtitle,
                keywords: ["edit", "workspace", "description", "notes", "markdown"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceName",
                title: constant(workspace.clearNameTitle),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceDescription",
                title: constant(workspace.clearDescriptionTitle),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "description", "notes"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomDescription)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleWorkspacePin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.workspaceShouldPin)
                        ? workspace.pinTitle
                        : workspace.unpinTitle
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.resetWorkspaceColor",
                title: constant(workspace.resetColorTitle),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "color", "reset", "clear", "palette"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(contentsOf: hostBlocks.workspaceColor)
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextWorkspace",
                title: constant(workspace.nextTitle),
                subtitle: constant(workspace.nextSubtitle),
                keywords: ["next", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousWorkspace",
                title: constant(workspace.previousTitle),
                subtitle: constant(workspace.previousSubtitle),
                keywords: ["previous", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceUp",
                title: constant(workspace.moveUpTitle),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "up", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceDown",
                title: constant(workspace.moveDownTitle),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "down", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceToTop",
                title: constant(workspace.moveToTopTitle),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "top", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeOtherWorkspaces",
                title: constant(workspace.closeOtherTitle),
                subtitle: workspaceSubtitle,
                keywords: ["close", "other", "workspaces", "reset", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasPeers) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesBelow",
                title: constant(workspace.closeBelowTitle),
                subtitle: workspaceSubtitle,
                keywords: ["close", "below", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesAbove",
                title: constant(workspace.closeAboveTitle),
                subtitle: workspaceSubtitle,
                keywords: ["close", "above", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceRead",
                title: constant(workspace.markReadTitle),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "read", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceCanMarkRead) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceUnread",
                title: constant(workspace.markUnreadTitle),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "unread", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceCanMarkUnread) }
            )
        )
        contributions.append(contentsOf: hostBlocks.identifierCopy)

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameTab",
                title: constant(tab.renameTitle),
                subtitle: panelSubtitle,
                keywords: ["rename", "tab", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearTabName",
                title: constant(tab.clearNameTitle),
                subtitle: panelSubtitle,
                keywords: ["clear", "tab", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasCustomName)
                }
            )
        )
        contributions.append(contentsOf: hostBlocks.moveTabToNewWorkspace)
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabPin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelShouldPin)
                        ? tab.pinTitle
                        : tab.unpinTitle
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabUnread",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelHasUnread)
                        ? tab.markReadTitle
                        : tab.markUnreadTitle
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextTabInPane",
                title: constant(tab.nextInPaneTitle),
                subtitle: constant(tab.nextInPaneSubtitle),
                keywords: ["next", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousTabInPane",
                title: constant(tab.previousInPaneTitle),
                subtitle: constant(tab.previousInPaneSubtitle),
                keywords: ["previous", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openWorkspacePullRequests",
                title: constant(workspace.openPullRequestsTitle),
                subtitle: workspaceSubtitle,
                keywords: ["pull", "request", "review", "merge", "pr", "mr", "open", "links", "workspace"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    $0.bool(CommandPaletteContextKeys.workspaceHasPullRequests)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openDiffViewer",
                title: constant(workspace.openDiffViewerTitle),
                subtitle: workspaceSubtitle,
                keywords: ["diff", "changes", "git", "review", "branch", "unstaged", "codeview", "agent", "codex", "claude"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openDirectoryDiffViewer",
                title: constant(workspace.openDirectoryDiffViewerTitle),
                subtitle: workspaceSubtitle,
                keywords: ["diff", "changes", "git", "review", "branch", "unstaged", "codeview", "directory", "cwd", "folder"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserBack",
                title: constant(browser.backTitle),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘[",
                keywords: ["browser", "back", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserForward",
                title: constant(browser.forwardTitle),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘]",
                keywords: ["browser", "forward", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReload",
                title: constant(browser.reloadTitle),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘R",
                keywords: ["browser", "reload", "refresh"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserOpenDefault",
                title: constant(browser.openDefaultTitle),
                subtitle: browserPanelSubtitle,
                keywords: ["open", "default", "external", "browser"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserFocusAddressBar",
                title: constant(browser.focusAddressBarTitle),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘L",
                keywords: ["browser", "address", "omnibar", "url"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserFocusMode",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelBrowserFocusModeActive)
                        ? browser.exitFocusModeTitle
                        : browser.enterFocusModeTitle
                },
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "focus", "mode", "keyboard", "shortcuts", "webview"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserToggleOmnibar",
                title: { context in
                    if context.bool(CommandPaletteContextKeys.panelBrowserOmnibarVisible) {
                        return browser.hideOmnibarTitle
                    }
                    return browser.showOmnibarTitle
                },
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "address", "omnibar", "url", "toolbar", "chrome", "show", "hide"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserToggleDevTools",
                title: constant(browser.toggleDevToolsTitle),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "devtools", "inspector"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserConsole",
                title: constant(browser.consoleTitle),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "console", "javascript"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReactGrab",
                title: constant(browser.reactGrabTitle),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "react", "grab", "inspect", "element"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomIn",
                title: constant(browser.zoomInTitle),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "in"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomOut",
                title: constant(browser.zoomOutTitle),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "out"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomReset",
                title: constant(browser.zoomResetTitle),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "reset", "actual size"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markdownZoomIn",
                title: constant(markdown.zoomInTitle),
                subtitle: markdownPanelSubtitle,
                keywords: ["markdown", "zoom", "in", "font", "size", "bigger", "larger"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsMarkdown) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markdownZoomOut",
                title: constant(markdown.zoomOutTitle),
                subtitle: markdownPanelSubtitle,
                keywords: ["markdown", "zoom", "out", "font", "size", "smaller"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsMarkdown) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markdownZoomReset",
                title: constant(markdown.zoomResetTitle),
                subtitle: markdownPanelSubtitle,
                keywords: ["markdown", "zoom", "reset", "actual size", "font", "default"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsMarkdown) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserClearHistory",
                title: constant(browser.clearHistoryTitle),
                subtitle: constant(browser.clearHistorySubtitle),
                keywords: ["browser", "history", "clear"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitRight",
                title: constant(browser.splitRightTitle),
                subtitle: constant(browser.splitRightSubtitle),
                keywords: ["browser", "split", "right"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsBrowser) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitDown",
                title: constant(browser.splitDownTitle),
                subtitle: constant(browser.splitDownSubtitle),
                keywords: ["browser", "split", "down"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsBrowser) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserDuplicateRight",
                title: constant(browser.duplicateRightTitle),
                subtitle: constant(browser.duplicateRightSubtitle),
                keywords: ["browser", "duplicate", "clone", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsBrowser) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )

        contributions.append(contentsOf: hostBlocks.terminalDirectoryOpenTargets)
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebStop",
                title: constant(terminal.vscodeServeWebStopTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "stop", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(rawValue: "vscodeInline"))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebRestart",
                title: constant(terminal.vscodeServeWebRestartTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "restart", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(rawValue: "vscodeInline"))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.findInDirectory",
                title: constant(terminal.findInDirectoryTitle),
                subtitle: constant(terminal.findInDirectorySubtitle),
                keywords: ["files", "directory", "find", "search"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFind",
                title: constant(terminal.findTitle),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘F",
                keywords: ["terminal", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindNext",
                title: constant(terminal.findNextTitle),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘G",
                keywords: ["terminal", "find", "next", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindPrevious",
                title: constant(terminal.findPreviousTitle),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌥⌘G",
                keywords: ["terminal", "find", "previous", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalHideFind",
                title: constant(terminal.hideFindTitle),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌥⌘⇧F",
                keywords: ["terminal", "hide", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalUseSelectionForFind",
                title: constant(terminal.useSelectionForFindTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "selection", "find"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalToggleTextBoxInput",
                title: constant(terminal.toggleTextBoxInputTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "textbox", "text", "box", "rich", "input", "prompt"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFocusTextBoxInput",
                title: constant(terminal.focusTextBoxInputTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "textbox", "text", "box", "rich", "input", "prompt", "focus"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalAttachTextBoxFile",
                title: constant(terminal.attachTextBoxFileTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "textbox", "text", "box", "rich", "input", "attach", "file", "image"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSendCtrlF",
                title: constant(terminal.sendCtrlFTitle),
                subtitle: terminalPanelSubtitle,
                keywords: [
                    "terminal", "ctrl", "control", "f", "send", "key", "passthrough",
                    "force", "stop", "agent", "agents", "claude", "code", "hung", "background", "watchdog", "kill",
                ],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalClearScreenKeepScrollback",
                title: constant(terminal.clearScreenKeepScrollbackTitle),
                subtitle: terminalPanelSubtitle,
                keywords: [
                    "terminal", "clear", "screen", "scrollback", "history", "keep",
                    "preserve", "reset", "wipe", "cls", "erase",
                ],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitRight",
                title: constant(split.terminalSplitRightTitle),
                subtitle: constant(split.terminalSplitRightSubtitle),
                keywords: ["terminal", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationRight",
                title: constant(fork.rightTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "right", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationLeft",
                title: constant(fork.leftTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "left", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationTop",
                title: constant(fork.topTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "top", "up", "above", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationBottom",
                title: constant(fork.bottomTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "bottom", "down", "below", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationNewTab",
                title: constant(fork.newTabTitle),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "new", "tab", "same", "pane"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationNewWorkspace",
                title: constant(fork.newWorkspaceTitle),
                subtitle: workspaceSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "new", "workspace"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitDown",
                title: constant(split.terminalSplitDownTitle),
                subtitle: constant(split.terminalSplitDownSubtitle),
                keywords: ["terminal", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserRight",
                title: constant(split.terminalSplitBrowserRightTitle),
                subtitle: constant(split.terminalSplitBrowserRightSubtitle),
                keywords: ["terminal", "split", "browser", "right"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserDown",
                title: constant(split.terminalSplitBrowserDownTitle),
                subtitle: constant(split.terminalSplitBrowserDownSubtitle),
                keywords: ["terminal", "split", "browser", "down"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSplitZoom",
                title: constant(split.toggleSplitZoomTitle),
                subtitle: constant(split.toggleSplitZoomSubtitle),
                keywords: ["terminal", "pane", "split", "zoom", "maximize"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    context.bool(CommandPaletteContextKeys.workspaceHasSplits)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.equalizeSplits",
                title: constant(workspace.equalizeSplitsTitle),
                subtitle: workspaceSubtitle,
                keywords: ["split", "equalize", "balance", "divider", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            )
        )

        contributions.append(contentsOf: hostBlocks.cmuxConfigIssues)
        contributions.append(contentsOf: hostBlocks.cmuxConfigCustomActions)

        return contributions
    }
}
