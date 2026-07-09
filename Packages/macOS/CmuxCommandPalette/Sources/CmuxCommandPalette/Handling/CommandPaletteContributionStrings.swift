import Foundation

/// The localized titles and subtitles for the static palette command catalog,
/// resolved app-side and handed to ``CommandPaletteContributionProvider``.
///
/// `String(localized:)` resolves against the *calling* bundle. Resolving it
/// inside this package would bind to the package bundle, which does not carry
/// the catalog's `Localizable.xcstrings` keys, silently dropping every
/// non-English (e.g. Japanese) translation. So the app resolves each string
/// once — preserving its existing key and default value — and passes the
/// already-resolved text across this seam. The provider owns the *structure*
/// (which command exists, its keywords, its `when`/`enablement` gates, and the
/// ordinal position of the host blocks); this struct carries only the display
/// text.
///
/// Context-dependent titles (toggles whose label flips on a snapshot bool)
/// carry *both* resolved variants here; the provider selects between them while
/// building each contribution's title closure, so the branch logic stays in the
/// package.
public struct CommandPaletteContributionStrings: Sendable, Equatable {
    /// Subtitle format pieces shared by the per-entity subtitle helpers.
    public let subtitle: Subtitle
    /// Global / app-level command strings.
    public let global: Global
    /// Layout and sidebar command strings.
    public let layout: Layout
    /// Notification command strings.
    public let notifications: Notifications
    /// Update command strings.
    public let updates: Updates
    /// Workspace command strings.
    public let workspace: Workspace
    /// Tab command strings.
    public let tab: Tab
    /// Browser command strings.
    public let browser: Browser
    /// Markdown command strings.
    public let markdown: Markdown
    /// Terminal command strings.
    public let terminal: Terminal
    /// Agent-fork command strings.
    public let fork: Fork
    /// Split command strings.
    public let split: Split

    /// Creates the catalog string bundle.
    public init(
        subtitle: Subtitle,
        global: Global,
        layout: Layout,
        notifications: Notifications,
        updates: Updates,
        workspace: Workspace,
        tab: Tab,
        browser: Browser,
        markdown: Markdown,
        terminal: Terminal,
        fork: Fork,
        split: Split
    ) {
        self.subtitle = subtitle
        self.global = global
        self.layout = layout
        self.notifications = notifications
        self.updates = updates
        self.workspace = workspace
        self.tab = tab
        self.browser = browser
        self.markdown = markdown
        self.terminal = terminal
        self.fork = fork
        self.split = split
    }

    /// Resolved subtitles produced by the per-entity subtitle helpers.
    ///
    /// The legacy helpers interpolate a context-derived name into a localized
    /// format. Because the format is localized, the app resolves the *whole*
    /// subtitle for both the named and the fallback case and passes the results;
    /// the provider picks the named variant when the snapshot carries a name.
    public struct Subtitle: Sendable, Equatable {
        /// Subtitle when a workspace name is present (`name` substituted).
        public let workspaceNamed: @Sendable (String) -> String
        /// Subtitle when no workspace name is present.
        public let workspaceFallback: String
        /// Subtitle when a panel name is present.
        public let panelNamed: @Sendable (String) -> String
        /// Subtitle when no panel name is present.
        public let panelFallback: String
        /// Subtitle when a browser panel name is present.
        public let browserNamed: @Sendable (String) -> String
        /// Subtitle when no browser panel name is present.
        public let browserFallback: String
        /// Subtitle when a terminal panel name is present.
        public let terminalNamed: @Sendable (String) -> String
        /// Subtitle when no terminal panel name is present.
        public let terminalFallback: String
        /// Subtitle when a markdown panel name is present.
        public let markdownNamed: @Sendable (String) -> String
        /// Subtitle when no markdown panel name is present.
        public let markdownFallback: String

        /// Creates the subtitle bundle.
        public init(
            workspaceNamed: @escaping @Sendable (String) -> String,
            workspaceFallback: String,
            panelNamed: @escaping @Sendable (String) -> String,
            panelFallback: String,
            browserNamed: @escaping @Sendable (String) -> String,
            browserFallback: String,
            terminalNamed: @escaping @Sendable (String) -> String,
            terminalFallback: String,
            markdownNamed: @escaping @Sendable (String) -> String,
            markdownFallback: String
        ) {
            self.workspaceNamed = workspaceNamed
            self.workspaceFallback = workspaceFallback
            self.panelNamed = panelNamed
            self.panelFallback = panelFallback
            self.browserNamed = browserNamed
            self.browserFallback = browserFallback
            self.terminalNamed = terminalNamed
            self.terminalFallback = terminalFallback
            self.markdownNamed = markdownNamed
            self.markdownFallback = markdownFallback
        }

        public static func == (lhs: Subtitle, rhs: Subtitle) -> Bool {
            lhs.workspaceFallback == rhs.workspaceFallback
                && lhs.panelFallback == rhs.panelFallback
                && lhs.browserFallback == rhs.browserFallback
                && lhs.terminalFallback == rhs.terminalFallback
                && lhs.markdownFallback == rhs.markdownFallback
        }
    }

    /// Global / app-level command strings.
    public struct Global: Sendable, Equatable {
        public let newWorkspaceTitle: String
        public let newWorkspaceSubtitle: String
        public let newBrowserWorkspaceTitle: String
        public let newBrowserWorkspaceSubtitle: String
        public let newWindowTitle: String
        public let newWindowSubtitle: String
        public let installCLITitle: String
        public let installCLISubtitle: String
        public let uninstallCLITitle: String
        public let uninstallCLISubtitle: String
        public let openFolderTitle: String
        public let openFolderSubtitle: String
        public let openFolderInVSCodeInlineTitle: String
        public let openFolderInVSCodeInlineSubtitle: String
        public let reopenPreviousSessionTitle: String
        public let reopenPreviousSessionSubtitle: String
        public let reopenClosedBrowserTabTitle: String
        public let reopenClosedBrowserTabSubtitle: String
        public let openSettingsTitle: String
        public let openSettingsSubtitle: String
        public let openCmuxSettingsFileTitle: String
        public let openCmuxSettingsFileSubtitle: String
        public let openGhosttySettingsTitle: String
        public let openGhosttySettingsSubtitle: String
        public let mobileConnectTitle: String
        public let mobileConnectSubtitle: String
        public let makeDefaultTerminalTitle: String
        public let makeDefaultTerminalSubtitle: String
        public let restartSocketListenerTitle: String
        public let restartSocketListenerSubtitle: String
        public let disableBrowserTitle: String
        public let disableBrowserSubtitle: String
        public let enableBrowserTitle: String
        public let enableBrowserSubtitle: String

        public init(
            newWorkspaceTitle: String,
            newWorkspaceSubtitle: String,
            newBrowserWorkspaceTitle: String,
            newBrowserWorkspaceSubtitle: String,
            newWindowTitle: String,
            newWindowSubtitle: String,
            installCLITitle: String,
            installCLISubtitle: String,
            uninstallCLITitle: String,
            uninstallCLISubtitle: String,
            openFolderTitle: String,
            openFolderSubtitle: String,
            openFolderInVSCodeInlineTitle: String,
            openFolderInVSCodeInlineSubtitle: String,
            reopenPreviousSessionTitle: String,
            reopenPreviousSessionSubtitle: String,
            reopenClosedBrowserTabTitle: String,
            reopenClosedBrowserTabSubtitle: String,
            openSettingsTitle: String,
            openSettingsSubtitle: String,
            openCmuxSettingsFileTitle: String,
            openCmuxSettingsFileSubtitle: String,
            openGhosttySettingsTitle: String,
            openGhosttySettingsSubtitle: String,
            mobileConnectTitle: String,
            mobileConnectSubtitle: String,
            makeDefaultTerminalTitle: String,
            makeDefaultTerminalSubtitle: String,
            restartSocketListenerTitle: String,
            restartSocketListenerSubtitle: String,
            disableBrowserTitle: String,
            disableBrowserSubtitle: String,
            enableBrowserTitle: String,
            enableBrowserSubtitle: String
        ) {
            self.newWorkspaceTitle = newWorkspaceTitle
            self.newWorkspaceSubtitle = newWorkspaceSubtitle
            self.newBrowserWorkspaceTitle = newBrowserWorkspaceTitle
            self.newBrowserWorkspaceSubtitle = newBrowserWorkspaceSubtitle
            self.newWindowTitle = newWindowTitle
            self.newWindowSubtitle = newWindowSubtitle
            self.installCLITitle = installCLITitle
            self.installCLISubtitle = installCLISubtitle
            self.uninstallCLITitle = uninstallCLITitle
            self.uninstallCLISubtitle = uninstallCLISubtitle
            self.openFolderTitle = openFolderTitle
            self.openFolderSubtitle = openFolderSubtitle
            self.openFolderInVSCodeInlineTitle = openFolderInVSCodeInlineTitle
            self.openFolderInVSCodeInlineSubtitle = openFolderInVSCodeInlineSubtitle
            self.reopenPreviousSessionTitle = reopenPreviousSessionTitle
            self.reopenPreviousSessionSubtitle = reopenPreviousSessionSubtitle
            self.reopenClosedBrowserTabTitle = reopenClosedBrowserTabTitle
            self.reopenClosedBrowserTabSubtitle = reopenClosedBrowserTabSubtitle
            self.openSettingsTitle = openSettingsTitle
            self.openSettingsSubtitle = openSettingsSubtitle
            self.openCmuxSettingsFileTitle = openCmuxSettingsFileTitle
            self.openCmuxSettingsFileSubtitle = openCmuxSettingsFileSubtitle
            self.openGhosttySettingsTitle = openGhosttySettingsTitle
            self.openGhosttySettingsSubtitle = openGhosttySettingsSubtitle
            self.mobileConnectTitle = mobileConnectTitle
            self.mobileConnectSubtitle = mobileConnectSubtitle
            self.makeDefaultTerminalTitle = makeDefaultTerminalTitle
            self.makeDefaultTerminalSubtitle = makeDefaultTerminalSubtitle
            self.restartSocketListenerTitle = restartSocketListenerTitle
            self.restartSocketListenerSubtitle = restartSocketListenerSubtitle
            self.disableBrowserTitle = disableBrowserTitle
            self.disableBrowserSubtitle = disableBrowserSubtitle
            self.enableBrowserTitle = enableBrowserTitle
            self.enableBrowserSubtitle = enableBrowserSubtitle
        }
    }

    /// Layout, tab-management, and sidebar command strings.
    public struct Layout: Sendable, Equatable {
        public let newTerminalTabTitle: String
        public let newTerminalTabSubtitle: String
        public let newBrowserTabTitle: String
        public let newBrowserTabSubtitle: String
        public let newAgentChatTitle: String
        public let newAgentChatSubtitle: String
        public let closeTabTitle: String
        public let closeTabSubtitle: String
        public let closeWorkspaceTitle: String
        public let closeWorkspaceSubtitle: String
        public let closeWindowTitle: String
        public let closeWindowSubtitle: String
        public let toggleFullScreenTitle: String
        public let toggleFullScreenSubtitle: String
        public let toggleSidebarTitle: String
        public let toggleSidebarSubtitle: String
        public let disableMatchTerminalBackgroundTitle: String
        public let enableMatchTerminalBackgroundTitle: String
        public let matchTerminalBackgroundSubtitle: String
        public let enableMinimalModeTitle: String
        public let disableMinimalModeTitle: String

        public init(
            newTerminalTabTitle: String,
            newTerminalTabSubtitle: String,
            newBrowserTabTitle: String,
            newBrowserTabSubtitle: String,
            newAgentChatTitle: String,
            newAgentChatSubtitle: String,
            closeTabTitle: String,
            closeTabSubtitle: String,
            closeWorkspaceTitle: String,
            closeWorkspaceSubtitle: String,
            closeWindowTitle: String,
            closeWindowSubtitle: String,
            toggleFullScreenTitle: String,
            toggleFullScreenSubtitle: String,
            toggleSidebarTitle: String,
            toggleSidebarSubtitle: String,
            disableMatchTerminalBackgroundTitle: String,
            enableMatchTerminalBackgroundTitle: String,
            matchTerminalBackgroundSubtitle: String,
            enableMinimalModeTitle: String,
            disableMinimalModeTitle: String
        ) {
            self.newTerminalTabTitle = newTerminalTabTitle
            self.newTerminalTabSubtitle = newTerminalTabSubtitle
            self.newBrowserTabTitle = newBrowserTabTitle
            self.newBrowserTabSubtitle = newBrowserTabSubtitle
            self.newAgentChatTitle = newAgentChatTitle
            self.newAgentChatSubtitle = newAgentChatSubtitle
            self.closeTabTitle = closeTabTitle
            self.closeTabSubtitle = closeTabSubtitle
            self.closeWorkspaceTitle = closeWorkspaceTitle
            self.closeWorkspaceSubtitle = closeWorkspaceSubtitle
            self.closeWindowTitle = closeWindowTitle
            self.closeWindowSubtitle = closeWindowSubtitle
            self.toggleFullScreenTitle = toggleFullScreenTitle
            self.toggleFullScreenSubtitle = toggleFullScreenSubtitle
            self.toggleSidebarTitle = toggleSidebarTitle
            self.toggleSidebarSubtitle = toggleSidebarSubtitle
            self.disableMatchTerminalBackgroundTitle = disableMatchTerminalBackgroundTitle
            self.enableMatchTerminalBackgroundTitle = enableMatchTerminalBackgroundTitle
            self.matchTerminalBackgroundSubtitle = matchTerminalBackgroundSubtitle
            self.enableMinimalModeTitle = enableMinimalModeTitle
            self.disableMinimalModeTitle = disableMinimalModeTitle
        }
    }

    /// Notification command strings.
    public struct Notifications: Sendable, Equatable {
        public let showNotificationsTitle: String
        public let showNotificationsSubtitle: String
        public let jumpUnreadTitle: String
        public let jumpUnreadSubtitle: String
        public let toggleUnreadTitle: String
        public let markOldestUnreadAndJumpNextTitle: String

        public init(
            showNotificationsTitle: String,
            showNotificationsSubtitle: String,
            jumpUnreadTitle: String,
            jumpUnreadSubtitle: String,
            toggleUnreadTitle: String,
            markOldestUnreadAndJumpNextTitle: String
        ) {
            self.showNotificationsTitle = showNotificationsTitle
            self.showNotificationsSubtitle = showNotificationsSubtitle
            self.jumpUnreadTitle = jumpUnreadTitle
            self.jumpUnreadSubtitle = jumpUnreadSubtitle
            self.toggleUnreadTitle = toggleUnreadTitle
            self.markOldestUnreadAndJumpNextTitle = markOldestUnreadAndJumpNextTitle
        }
    }

    /// Update command strings.
    public struct Updates: Sendable, Equatable {
        public let checkForUpdatesTitle: String
        public let checkForUpdatesSubtitle: String
        public let applyUpdateIfAvailableTitle: String
        public let applyUpdateIfAvailableSubtitle: String
        public let attemptUpdateTitle: String
        public let attemptUpdateSubtitle: String

        public init(
            checkForUpdatesTitle: String,
            checkForUpdatesSubtitle: String,
            applyUpdateIfAvailableTitle: String,
            applyUpdateIfAvailableSubtitle: String,
            attemptUpdateTitle: String,
            attemptUpdateSubtitle: String
        ) {
            self.checkForUpdatesTitle = checkForUpdatesTitle
            self.checkForUpdatesSubtitle = checkForUpdatesSubtitle
            self.applyUpdateIfAvailableTitle = applyUpdateIfAvailableTitle
            self.applyUpdateIfAvailableSubtitle = applyUpdateIfAvailableSubtitle
            self.attemptUpdateTitle = attemptUpdateTitle
            self.attemptUpdateSubtitle = attemptUpdateSubtitle
        }
    }

    /// Workspace command strings.
    public struct Workspace: Sendable, Equatable {
        public let renameTitle: String
        public let editDescriptionTitle: String
        public let clearNameTitle: String
        public let clearDescriptionTitle: String
        public let pinTitle: String
        public let unpinTitle: String
        public let resetColorTitle: String
        public let nextTitle: String
        public let nextSubtitle: String
        public let previousTitle: String
        public let previousSubtitle: String
        public let moveUpTitle: String
        public let moveDownTitle: String
        public let moveToTopTitle: String
        public let closeOtherTitle: String
        public let closeBelowTitle: String
        public let closeAboveTitle: String
        public let markReadTitle: String
        public let markUnreadTitle: String
        public let openPullRequestsTitle: String
        public let openDiffViewerTitle: String
        public let openDirectoryDiffViewerTitle: String
        public let equalizeSplitsTitle: String

        public init(
            renameTitle: String,
            editDescriptionTitle: String,
            clearNameTitle: String,
            clearDescriptionTitle: String,
            pinTitle: String,
            unpinTitle: String,
            resetColorTitle: String,
            nextTitle: String,
            nextSubtitle: String,
            previousTitle: String,
            previousSubtitle: String,
            moveUpTitle: String,
            moveDownTitle: String,
            moveToTopTitle: String,
            closeOtherTitle: String,
            closeBelowTitle: String,
            closeAboveTitle: String,
            markReadTitle: String,
            markUnreadTitle: String,
            openPullRequestsTitle: String,
            openDiffViewerTitle: String,
            openDirectoryDiffViewerTitle: String,
            equalizeSplitsTitle: String
        ) {
            self.renameTitle = renameTitle
            self.editDescriptionTitle = editDescriptionTitle
            self.clearNameTitle = clearNameTitle
            self.clearDescriptionTitle = clearDescriptionTitle
            self.pinTitle = pinTitle
            self.unpinTitle = unpinTitle
            self.resetColorTitle = resetColorTitle
            self.nextTitle = nextTitle
            self.nextSubtitle = nextSubtitle
            self.previousTitle = previousTitle
            self.previousSubtitle = previousSubtitle
            self.moveUpTitle = moveUpTitle
            self.moveDownTitle = moveDownTitle
            self.moveToTopTitle = moveToTopTitle
            self.closeOtherTitle = closeOtherTitle
            self.closeBelowTitle = closeBelowTitle
            self.closeAboveTitle = closeAboveTitle
            self.markReadTitle = markReadTitle
            self.markUnreadTitle = markUnreadTitle
            self.openPullRequestsTitle = openPullRequestsTitle
            self.openDiffViewerTitle = openDiffViewerTitle
            self.openDirectoryDiffViewerTitle = openDirectoryDiffViewerTitle
            self.equalizeSplitsTitle = equalizeSplitsTitle
        }
    }

    /// Tab command strings.
    public struct Tab: Sendable, Equatable {
        public let renameTitle: String
        public let clearNameTitle: String
        public let pinTitle: String
        public let unpinTitle: String
        public let markReadTitle: String
        public let markUnreadTitle: String
        public let nextInPaneTitle: String
        public let nextInPaneSubtitle: String
        public let previousInPaneTitle: String
        public let previousInPaneSubtitle: String

        public init(
            renameTitle: String,
            clearNameTitle: String,
            pinTitle: String,
            unpinTitle: String,
            markReadTitle: String,
            markUnreadTitle: String,
            nextInPaneTitle: String,
            nextInPaneSubtitle: String,
            previousInPaneTitle: String,
            previousInPaneSubtitle: String
        ) {
            self.renameTitle = renameTitle
            self.clearNameTitle = clearNameTitle
            self.pinTitle = pinTitle
            self.unpinTitle = unpinTitle
            self.markReadTitle = markReadTitle
            self.markUnreadTitle = markUnreadTitle
            self.nextInPaneTitle = nextInPaneTitle
            self.nextInPaneSubtitle = nextInPaneSubtitle
            self.previousInPaneTitle = previousInPaneTitle
            self.previousInPaneSubtitle = previousInPaneSubtitle
        }
    }

    /// Browser command strings.
    public struct Browser: Sendable, Equatable {
        public let backTitle: String
        public let forwardTitle: String
        public let reloadTitle: String
        public let openDefaultTitle: String
        public let focusAddressBarTitle: String
        public let enterFocusModeTitle: String
        public let exitFocusModeTitle: String
        public let showOmnibarTitle: String
        public let hideOmnibarTitle: String
        public let toggleDevToolsTitle: String
        public let consoleTitle: String
        public let reactGrabTitle: String
        public let zoomInTitle: String
        public let zoomOutTitle: String
        public let zoomResetTitle: String
        public let clearHistoryTitle: String
        public let clearHistorySubtitle: String
        public let splitRightTitle: String
        public let splitRightSubtitle: String
        public let splitDownTitle: String
        public let splitDownSubtitle: String
        public let duplicateRightTitle: String
        public let duplicateRightSubtitle: String

        public init(
            backTitle: String,
            forwardTitle: String,
            reloadTitle: String,
            openDefaultTitle: String,
            focusAddressBarTitle: String,
            enterFocusModeTitle: String,
            exitFocusModeTitle: String,
            showOmnibarTitle: String,
            hideOmnibarTitle: String,
            toggleDevToolsTitle: String,
            consoleTitle: String,
            reactGrabTitle: String,
            zoomInTitle: String,
            zoomOutTitle: String,
            zoomResetTitle: String,
            clearHistoryTitle: String,
            clearHistorySubtitle: String,
            splitRightTitle: String,
            splitRightSubtitle: String,
            splitDownTitle: String,
            splitDownSubtitle: String,
            duplicateRightTitle: String,
            duplicateRightSubtitle: String
        ) {
            self.backTitle = backTitle
            self.forwardTitle = forwardTitle
            self.reloadTitle = reloadTitle
            self.openDefaultTitle = openDefaultTitle
            self.focusAddressBarTitle = focusAddressBarTitle
            self.enterFocusModeTitle = enterFocusModeTitle
            self.exitFocusModeTitle = exitFocusModeTitle
            self.showOmnibarTitle = showOmnibarTitle
            self.hideOmnibarTitle = hideOmnibarTitle
            self.toggleDevToolsTitle = toggleDevToolsTitle
            self.consoleTitle = consoleTitle
            self.reactGrabTitle = reactGrabTitle
            self.zoomInTitle = zoomInTitle
            self.zoomOutTitle = zoomOutTitle
            self.zoomResetTitle = zoomResetTitle
            self.clearHistoryTitle = clearHistoryTitle
            self.clearHistorySubtitle = clearHistorySubtitle
            self.splitRightTitle = splitRightTitle
            self.splitRightSubtitle = splitRightSubtitle
            self.splitDownTitle = splitDownTitle
            self.splitDownSubtitle = splitDownSubtitle
            self.duplicateRightTitle = duplicateRightTitle
            self.duplicateRightSubtitle = duplicateRightSubtitle
        }
    }

    /// Markdown command strings.
    public struct Markdown: Sendable, Equatable {
        public let zoomInTitle: String
        public let zoomOutTitle: String
        public let zoomResetTitle: String

        public init(zoomInTitle: String, zoomOutTitle: String, zoomResetTitle: String) {
            self.zoomInTitle = zoomInTitle
            self.zoomOutTitle = zoomOutTitle
            self.zoomResetTitle = zoomResetTitle
        }
    }

    /// Terminal command strings.
    public struct Terminal: Sendable, Equatable {
        public let vscodeServeWebStopTitle: String
        public let vscodeServeWebRestartTitle: String
        public let findInDirectoryTitle: String
        public let findInDirectorySubtitle: String
        public let findTitle: String
        public let findNextTitle: String
        public let findPreviousTitle: String
        public let hideFindTitle: String
        public let useSelectionForFindTitle: String
        public let toggleTextBoxInputTitle: String
        public let focusTextBoxInputTitle: String
        public let attachTextBoxFileTitle: String
        public let sendCtrlFTitle: String
        public let clearScreenKeepScrollbackTitle: String

        public init(
            vscodeServeWebStopTitle: String,
            vscodeServeWebRestartTitle: String,
            findInDirectoryTitle: String,
            findInDirectorySubtitle: String,
            findTitle: String,
            findNextTitle: String,
            findPreviousTitle: String,
            hideFindTitle: String,
            useSelectionForFindTitle: String,
            toggleTextBoxInputTitle: String,
            focusTextBoxInputTitle: String,
            attachTextBoxFileTitle: String,
            sendCtrlFTitle: String,
            clearScreenKeepScrollbackTitle: String
        ) {
            self.vscodeServeWebStopTitle = vscodeServeWebStopTitle
            self.vscodeServeWebRestartTitle = vscodeServeWebRestartTitle
            self.findInDirectoryTitle = findInDirectoryTitle
            self.findInDirectorySubtitle = findInDirectorySubtitle
            self.findTitle = findTitle
            self.findNextTitle = findNextTitle
            self.findPreviousTitle = findPreviousTitle
            self.hideFindTitle = hideFindTitle
            self.useSelectionForFindTitle = useSelectionForFindTitle
            self.toggleTextBoxInputTitle = toggleTextBoxInputTitle
            self.focusTextBoxInputTitle = focusTextBoxInputTitle
            self.attachTextBoxFileTitle = attachTextBoxFileTitle
            self.sendCtrlFTitle = sendCtrlFTitle
            self.clearScreenKeepScrollbackTitle = clearScreenKeepScrollbackTitle
        }
    }

    /// Agent-conversation fork command strings.
    public struct Fork: Sendable, Equatable {
        public let rightTitle: String
        public let leftTitle: String
        public let topTitle: String
        public let bottomTitle: String
        public let newTabTitle: String
        public let newWorkspaceTitle: String

        public init(
            rightTitle: String,
            leftTitle: String,
            topTitle: String,
            bottomTitle: String,
            newTabTitle: String,
            newWorkspaceTitle: String
        ) {
            self.rightTitle = rightTitle
            self.leftTitle = leftTitle
            self.topTitle = topTitle
            self.bottomTitle = bottomTitle
            self.newTabTitle = newTabTitle
            self.newWorkspaceTitle = newWorkspaceTitle
        }
    }

    /// Terminal-split command strings.
    public struct Split: Sendable, Equatable {
        public let terminalSplitRightTitle: String
        public let terminalSplitRightSubtitle: String
        public let terminalSplitDownTitle: String
        public let terminalSplitDownSubtitle: String
        public let terminalSplitBrowserRightTitle: String
        public let terminalSplitBrowserRightSubtitle: String
        public let terminalSplitBrowserDownTitle: String
        public let terminalSplitBrowserDownSubtitle: String
        public let toggleSplitZoomTitle: String
        public let toggleSplitZoomSubtitle: String
        public let toggleFullWidthTabTitle: String

        public init(
            terminalSplitRightTitle: String,
            terminalSplitRightSubtitle: String,
            terminalSplitDownTitle: String,
            terminalSplitDownSubtitle: String,
            terminalSplitBrowserRightTitle: String,
            terminalSplitBrowserRightSubtitle: String,
            terminalSplitBrowserDownTitle: String,
            terminalSplitBrowserDownSubtitle: String,
            toggleSplitZoomTitle: String,
            toggleSplitZoomSubtitle: String,
            toggleFullWidthTabTitle: String
        ) {
            self.terminalSplitRightTitle = terminalSplitRightTitle
            self.terminalSplitRightSubtitle = terminalSplitRightSubtitle
            self.terminalSplitDownTitle = terminalSplitDownTitle
            self.terminalSplitDownSubtitle = terminalSplitDownSubtitle
            self.terminalSplitBrowserRightTitle = terminalSplitBrowserRightTitle
            self.terminalSplitBrowserRightSubtitle = terminalSplitBrowserRightSubtitle
            self.terminalSplitBrowserDownTitle = terminalSplitBrowserDownTitle
            self.terminalSplitBrowserDownSubtitle = terminalSplitBrowserDownSubtitle
            self.toggleSplitZoomTitle = toggleSplitZoomTitle
            self.toggleSplitZoomSubtitle = toggleSplitZoomSubtitle
            self.toggleFullWidthTabTitle = toggleFullWidthTabTitle
        }
    }
}
