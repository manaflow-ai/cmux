import Testing
@testable import CmuxCommandPalette

@Suite("CommandPaletteContributionProvider")
struct CommandPaletteContributionProviderTests {
    private func makeStrings() -> CommandPaletteContributionStrings {
        CommandPaletteContributionStrings(
            subtitle: CommandPaletteContributionStrings.Subtitle(
                workspaceNamed: { "Workspace • \($0)" },
                workspaceFallback: "Workspace • Workspace",
                panelNamed: { "Tab • \($0)" },
                panelFallback: "Tab • Tab",
                browserNamed: { "Browser • \($0)" },
                browserFallback: "Browser • Tab",
                terminalNamed: { "Terminal • \($0)" },
                terminalFallback: "Terminal • Tab",
                markdownNamed: { "Markdown • \($0)" },
                markdownFallback: "Markdown • Tab"
            ),
            global: CommandPaletteContributionStrings.Global(
                newWorkspaceTitle: "New Workspace", newWorkspaceSubtitle: "Workspace",
                newBrowserWorkspaceTitle: "New Browser Workspace", newBrowserWorkspaceSubtitle: "Workspace",
                newWindowTitle: "New Window", newWindowSubtitle: "Window",
                installCLITitle: "Install CLI", installCLISubtitle: "CLI",
                uninstallCLITitle: "Uninstall CLI", uninstallCLISubtitle: "CLI",
                openFolderTitle: "Open Folder", openFolderSubtitle: "Workspace",
                openFolderInVSCodeInlineTitle: "Open Inline", openFolderInVSCodeInlineSubtitle: "VS Code Inline",
                reopenPreviousSessionTitle: "Restore", reopenPreviousSessionSubtitle: "History",
                reopenClosedBrowserTabTitle: "Reopen Last Closed", reopenClosedBrowserTabSubtitle: "History",
                openSettingsTitle: "Open Settings", openSettingsSubtitle: "Global",
                openCmuxSettingsFileTitle: "Open cmux.json", openCmuxSettingsFileSubtitle: "cmux.json",
                openGhosttySettingsTitle: "Open Ghostty", openGhosttySettingsSubtitle: "Ghostty",
                mobileConnectTitle: "Connect", mobileConnectSubtitle: "Mobile",
                makeDefaultTerminalTitle: "Make Default", makeDefaultTerminalSubtitle: "Global",
                restartSocketListenerTitle: "Restart CLI Listener", restartSocketListenerSubtitle: "Global",
                disableBrowserTitle: "Disable Browser", disableBrowserSubtitle: "Browser",
                enableBrowserTitle: "Enable Browser", enableBrowserSubtitle: "Browser"
            ),
            layout: CommandPaletteContributionStrings.Layout(
                newTerminalTabTitle: "New Tab", newTerminalTabSubtitle: "Tab",
                newBrowserTabTitle: "New Browser Tab", newBrowserTabSubtitle: "Tab",
                closeTabTitle: "Close Tab", closeTabSubtitle: "Tab",
                closeWorkspaceTitle: "Close Workspace", closeWorkspaceSubtitle: "Workspace",
                closeWindowTitle: "Close Window", closeWindowSubtitle: "Window",
                toggleFullScreenTitle: "Full Screen", toggleFullScreenSubtitle: "Window",
                toggleSidebarTitle: "Toggle Sidebar", toggleSidebarSubtitle: "Layout",
                disableMatchTerminalBackgroundTitle: "Disable Match", enableMatchTerminalBackgroundTitle: "Enable Match",
                matchTerminalBackgroundSubtitle: "Sidebar",
                enableMinimalModeTitle: "Enable Minimal", disableMinimalModeTitle: "Disable Minimal"
            ),
            notifications: CommandPaletteContributionStrings.Notifications(
                showNotificationsTitle: "Show", showNotificationsSubtitle: "Notifications",
                jumpUnreadTitle: "Jump", jumpUnreadSubtitle: "Notifications",
                toggleUnreadTitle: "Toggle Unread", markOldestUnreadAndJumpNextTitle: "Mark Oldest"
            ),
            updates: CommandPaletteContributionStrings.Updates(
                checkForUpdatesTitle: "Check", checkForUpdatesSubtitle: "Global",
                applyUpdateIfAvailableTitle: "Apply", applyUpdateIfAvailableSubtitle: "Global",
                attemptUpdateTitle: "Attempt", attemptUpdateSubtitle: "Global"
            ),
            workspace: CommandPaletteContributionStrings.Workspace(
                renameTitle: "Rename WS", editDescriptionTitle: "Edit Desc",
                clearNameTitle: "Clear Name", clearDescriptionTitle: "Clear Desc",
                pinTitle: "Pin", unpinTitle: "Unpin", resetColorTitle: "Reset Color",
                nextTitle: "Next WS", nextSubtitle: "Nav", previousTitle: "Prev WS", previousSubtitle: "Nav",
                moveUpTitle: "Up", moveDownTitle: "Down", moveToTopTitle: "Top",
                closeOtherTitle: "Close Other", closeBelowTitle: "Close Below", closeAboveTitle: "Close Above",
                markReadTitle: "Mark Read", markUnreadTitle: "Mark Unread",
                openPullRequestsTitle: "Open PRs", openDiffViewerTitle: "Diff",
                openDirectoryDiffViewerTitle: "Directory Diff", equalizeSplitsTitle: "Equalize"
            ),
            tab: CommandPaletteContributionStrings.Tab(
                renameTitle: "Rename Tab", clearNameTitle: "Clear Tab Name",
                pinTitle: "Pin Tab", unpinTitle: "Unpin Tab",
                markReadTitle: "Mark Tab Read", markUnreadTitle: "Mark Tab Unread",
                nextInPaneTitle: "Next In Pane", nextInPaneSubtitle: "Nav",
                previousInPaneTitle: "Prev In Pane", previousInPaneSubtitle: "Nav"
            ),
            browser: CommandPaletteContributionStrings.Browser(
                backTitle: "Back", forwardTitle: "Forward", reloadTitle: "Reload",
                openDefaultTitle: "Open Default", focusAddressBarTitle: "Focus Bar",
                enterFocusModeTitle: "Enter Focus", exitFocusModeTitle: "Exit Focus",
                showOmnibarTitle: "Show Omnibar", hideOmnibarTitle: "Hide Omnibar",
                toggleDevToolsTitle: "DevTools", consoleTitle: "Console", reactGrabTitle: "React Grab",
                zoomInTitle: "Zoom In", zoomOutTitle: "Zoom Out", zoomResetTitle: "Actual Size",
                clearHistoryTitle: "Clear History", clearHistorySubtitle: "Browser",
                splitRightTitle: "Split Right", splitRightSubtitle: "Browser Layout",
                splitDownTitle: "Split Down", splitDownSubtitle: "Browser Layout",
                duplicateRightTitle: "Duplicate", duplicateRightSubtitle: "Browser Layout"
            ),
            markdown: CommandPaletteContributionStrings.Markdown(
                zoomInTitle: "MD Zoom In", zoomOutTitle: "MD Zoom Out", zoomResetTitle: "MD Actual Size"
            ),
            terminal: CommandPaletteContributionStrings.Terminal(
                vscodeServeWebStopTitle: "Stop", vscodeServeWebRestartTitle: "Restart",
                findInDirectoryTitle: "Find In Dir", findInDirectorySubtitle: "Right Sidebar",
                findTitle: "Find", findNextTitle: "Find Next", findPreviousTitle: "Find Prev",
                hideFindTitle: "Hide Find", useSelectionForFindTitle: "Use Selection",
                toggleTextBoxInputTitle: "Toggle TextBox", focusTextBoxInputTitle: "Focus TextBox",
                attachTextBoxFileTitle: "Attach File", sendCtrlFTitle: "Send Ctrl-F",
                clearScreenKeepScrollbackTitle: "Clear Screen"
            ),
            fork: CommandPaletteContributionStrings.Fork(
                rightTitle: "Fork Right", leftTitle: "Fork Left", topTitle: "Fork Top",
                bottomTitle: "Fork Bottom", newTabTitle: "Fork New Tab", newWorkspaceTitle: "Fork New WS"
            ),
            split: CommandPaletteContributionStrings.Split(
                terminalSplitRightTitle: "Split Right", terminalSplitRightSubtitle: "Terminal Layout",
                terminalSplitDownTitle: "Split Down", terminalSplitDownSubtitle: "Terminal Layout",
                terminalSplitBrowserRightTitle: "Split Browser Right", terminalSplitBrowserRightSubtitle: "Terminal Layout",
                terminalSplitBrowserDownTitle: "Split Browser Down", terminalSplitBrowserDownSubtitle: "Terminal Layout",
                toggleSplitZoomTitle: "Pane Zoom", toggleSplitZoomSubtitle: "Terminal Layout",
                toggleFullWidthTabTitle: "Full Width Tab"
            )
        )
    }

    private func sentinel(_ id: String) -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(commandId: id, title: { _ in id }, subtitle: { _ in id })
    }

    @Test func interleavesHostBlocksAtLegacyOrdinals() {
        let provider = CommandPaletteContributionProvider()
        let hostBlocks = CommandPaletteContributionHostBlocks(
            vscodeInlineAvailable: { true },
            extensionSidebar: [sentinel("host.extensionSidebar")],
            rightSidebarMode: [sentinel("host.rightSidebarMode")],
            rightSidebarToolPane: [sentinel("host.rightSidebarToolPane")],
            view: [sentinel("host.view")],
            canvas: [sentinel("host.canvas")],
            cloud: [sentinel("host.cloud")],
            mobileConnectKeywords: ["mobile"],
            makeDefaultTerminalKeywords: ["default"],
            auth: [sentinel("host.auth")],
            settingsToggle: [sentinel("host.settingsToggle")],
            workspaceColor: [sentinel("host.workspaceColor")],
            identifierCopy: [sentinel("host.identifierCopy")],
            moveTabToNewWorkspace: [sentinel("host.moveTab")],
            terminalDirectoryOpenTargets: [sentinel("host.terminalDirectoryOpenTargets")],
            cmuxConfigIssues: [sentinel("host.cmuxConfigIssues")],
            cmuxConfigCustomActions: [sentinel("host.cmuxConfigCustomActions")]
        )
        let ids = provider.build(strings: makeStrings(), hostBlocks: hostBlocks).map(\.commandId)

        // Built-in command before each host block, and the block lands right after.
        func assertAfter(_ block: String, follows builtin: String) {
            let bi = ids.firstIndex(of: builtin)
            let bl = ids.firstIndex(of: block)
            #expect(bi != nil && bl != nil, "missing \(builtin) or \(block)")
            if let bi, let bl { #expect(bl == bi + 1, "\(block) should immediately follow \(builtin)") }
        }
        assertAfter("host.extensionSidebar", follows: "palette.toggleSidebar")
        assertAfter("host.rightSidebarMode", follows: "host.extensionSidebar")
        assertAfter("host.workspaceColor", follows: "palette.resetWorkspaceColor")
        assertAfter("host.identifierCopy", follows: "palette.markWorkspaceUnread")
        assertAfter("host.moveTab", follows: "palette.clearTabName")
        assertAfter("host.terminalDirectoryOpenTargets", follows: "palette.browserDuplicateRight")
        assertAfter("host.cmuxConfigIssues", follows: "palette.equalizeSplits")
        assertAfter("host.cmuxConfigCustomActions", follows: "host.cmuxConfigIssues")
        #expect(ids.first == "host.cloud")
        #expect(ids.contains("palette.openDirectoryDiffViewer"))
        // cmuxConfigCustomActions is the final block.
        #expect(ids.last == "host.cmuxConfigCustomActions")
    }

    @Test func contextDependentTitlesAndGatingHold() throws {
        let provider = CommandPaletteContributionProvider()
        let contributions = provider.build(strings: makeStrings(), hostBlocks: CommandPaletteContributionHostBlocks())
        let byId = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })

        // Toggle title flips on the snapshot bool.
        var pinned = CommandPaletteContextSnapshot()
        pinned.setBool(CommandPaletteContextKeys.workspaceShouldPin, true)
        var unpinned = CommandPaletteContextSnapshot()
        unpinned.setBool(CommandPaletteContextKeys.workspaceShouldPin, false)
        let pinCmd = try #require(byId["palette.toggleWorkspacePin"])
        #expect(pinCmd.title(pinned) == "Pin")
        #expect(pinCmd.title(unpinned) == "Unpin")

        // Subtitle uses the named variant when a name is present, fallback otherwise.
        var named = CommandPaletteContextSnapshot()
        named.setString(CommandPaletteContextKeys.workspaceName, "Alpha")
        #expect(pinCmd.subtitle(named) == "Workspace • Alpha")
        #expect(pinCmd.subtitle(CommandPaletteContextSnapshot()) == "Workspace • Workspace")

        // newBrowserWorkspace is gated off when the browser is disabled.
        let nbw = byId["palette.newBrowserWorkspace"]
        var browserOff = CommandPaletteContextSnapshot()
        browserOff.setBool(CommandPaletteContextKeys.browserDisabled, true)
        #expect(nbw?.when(CommandPaletteContextSnapshot()) == true)
        #expect(nbw?.when(browserOff) == false)
    }
}
