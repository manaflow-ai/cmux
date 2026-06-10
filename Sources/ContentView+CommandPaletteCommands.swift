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


// MARK: - Command palette command construction and shortcut hints
extension ContentView {
    func commandPaletteCommandsContext(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>
    ) -> CommandPaletteCommandsContext {
        let cliInstalledInPATH = AppDelegate.shared?.isCmuxCLIInstalledInPATH() ?? false
        var snapshot = commandPaletteContextSnapshot(terminalOpenTargets: terminalOpenTargets)
        snapshot.setBool(CommandPaletteContextKeys.cliInstalledInPATH, cliInstalledInPATH)
        snapshot.setBool(
            CommandPaletteContextKeys.defaultTerminalIsDefault,
            cachedDefaultTerminalIsDefault
        )
        return CommandPaletteCommandsContext(
            snapshot: snapshot
        )
    }

    func commandPaletteCommands(
        commandsContext: CommandPaletteCommandsContext
    ) -> [CommandPaletteCommand] {
        let context = commandsContext.snapshot
        let contributions = commandPaletteCommandContributions()
        var handlerRegistry = CommandPaletteHandlerRegistry()
        registerCommandPaletteHandlers(&handlerRegistry)

        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(contributions.count)
        var nextRank = 0

        for contribution in contributions {
            let configuredPaletteAction = commandPaletteConfigActionID(for: contribution.commandId)
                .flatMap { cmuxConfigStore.resolvedAction(id: $0) }
            if let configuredPaletteAction, !configuredPaletteAction.palette {
                continue
            }
            guard contribution.when(context), contribution.enablement(context) else { continue }
            guard let action = handlerRegistry.handler(for: contribution.commandId) else {
                assertionFailure("No command palette handler registered for \(contribution.commandId)")
                continue
            }
            commands.append(
                CommandPaletteCommand(
                    id: contribution.commandId,
                    rank: nextRank,
                    title: configuredPaletteAction?.title ?? contribution.title(context),
                    subtitle: configuredPaletteAction?.subtitle ?? contribution.subtitle(context),
                    shortcutHint: commandPaletteShortcutHint(for: contribution, context: context),
                    kindLabel: nil,
                    keywords: configuredPaletteAction?.keywords.isEmpty == false
                        ? configuredPaletteAction?.keywords ?? contribution.keywords
                        : contribution.keywords,
                    dismissOnRun: contribution.dismissOnRun,
                    action: action
                )
            )
            nextRank += 1
        }

        return commands
    }

    private func commandPaletteConfigActionID(for commandId: String) -> String? {
        switch commandId {
        case "palette.newTerminalTab":
            return CmuxSurfaceTabBarBuiltInAction.newTerminal.configID
        case "palette.newBrowserTab":
            return CmuxSurfaceTabBarBuiltInAction.newBrowser.configID
        case "palette.terminalSplitRight":
            return CmuxSurfaceTabBarBuiltInAction.splitRight.configID
        case "palette.terminalSplitDown":
            return CmuxSurfaceTabBarBuiltInAction.splitDown.configID
        default:
            return nil
        }
    }

    private func commandPaletteShortcutHint(
        for contribution: CommandPaletteCommandContribution,
        context: CommandPaletteContextSnapshot
    ) -> String? {
        if let configuredShortcut = cmuxConfigStore.resolvedAction(id: contribution.commandId)?.shortcut {
            return configuredShortcut.displayString
        }
        if let configuredPaletteAction = commandPaletteConfigActionID(for: contribution.commandId),
           let configuredShortcut = cmuxConfigStore.resolvedAction(id: configuredPaletteAction)?.shortcut {
            return configuredShortcut.displayString
        }
        if let action = Self.commandPaletteShortcutAction(forCommandID: contribution.commandId) {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard !shortcut.isUnbound else { return nil }
            guard action.shortcutContext.isAvailable(
                focusedBrowserPanel: context.bool(CommandPaletteContextKeys.panelIsBrowser),
                focusedMarkdownPanel: context.bool(CommandPaletteContextKeys.panelIsMarkdown),
                rightSidebarFocused: false
            ) else {
                return nil
            }
            return shortcut.displayString
        }
        if let staticShortcut = commandPaletteStaticShortcutHint(for: contribution.commandId) {
            return staticShortcut
        }
        return contribution.shortcutHint
    }

    private func commandPaletteStaticShortcutHint(for commandId: String) -> String? {
        switch commandId {
        case "palette.closeTab":
            return "⌘W"
        case "palette.closeWorkspace":
            return "⌘⇧W"
        case "palette.openSettings":
            return "⌘,"
        case "palette.browserBack":
            return "⌘["
        case "palette.browserForward":
            return "⌘]"
        case "palette.browserReload":
            return "⌘R"
        case "palette.browserFocusAddressBar":
            return "⌘L"
        case "palette.browserZoomIn":
            return "⌘="
        case "palette.browserZoomOut":
            return "⌘-"
        case "palette.browserZoomReset":
            return "⌘0"
        case "palette.markdownZoomIn":
            return "⌘="
        case "palette.markdownZoomOut":
            return "⌘-"
        case "palette.markdownZoomReset":
            return "⌘0"
        case "palette.terminalFind":
            return "⌘F"
        case "palette.terminalFindNext":
            return "⌘G"
        case "palette.terminalFindPrevious":
            return "⌥⌘G"
        case "palette.terminalHideFind":
            return "⌥⌘⇧F"
        case "palette.terminalUseSelectionForFind":
            return "⌘E"
        case "palette.toggleFullScreen":
            return "\u{2303}\u{2318}F"
        default:
            return nil
        }
    }

    private func commandPaletteContextSnapshot(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>? = nil
    ) -> CommandPaletteContextSnapshot {
        var snapshot = CommandPaletteContextSnapshot()
        snapshot.setBool(CommandPaletteContextKeys.workspaceMinimalModeEnabled, isMinimalMode)
        snapshot.setBool(CommandPaletteContextKeys.sidebarMatchTerminalBackground, sidebarMatchTerminalBackground)
        snapshot.setBool(CommandPaletteContextKeys.browserDisabled, BrowserAvailabilitySettings.isDisabled())
        if let auth = AppDelegate.shared?.auth {
            snapshot.setBool(CommandPaletteContextKeys.authSignedIn, auth.coordinator.isAuthenticated)
            snapshot.setBool(
                CommandPaletteContextKeys.authWorking,
                auth.coordinator.isLoading || auth.coordinator.isRestoringSession || auth.browserSignIn.isSigningIn
            )
        }

        if let workspace = tabManager.selectedWorkspace {
            let pinTarget = WorkspaceActionDispatcher.Target.single(workspace.id)
            let pinState = WorkspaceActionDispatcher.pinState(in: tabManager, target: pinTarget)
            snapshot.setBool(CommandPaletteContextKeys.hasWorkspace, true)
            snapshot.setString(CommandPaletteContextKeys.workspaceName, workspaceDisplayName(workspace))
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomName, workspace.customTitle != nil)
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomDescription, workspace.hasCustomDescription)
            snapshot.setBool(CommandPaletteContextKeys.workspaceShouldPin, pinState?.pinned ?? !workspace.isPinned)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasPullRequests,
                !workspace.sidebarPullRequestsInDisplayOrder().isEmpty
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasSplits,
                workspace.bonsplitController.allPaneIds.count > 1
            )
            let workspaceIndex = tabManager.tabs.firstIndex { $0.id == workspace.id }
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasPeers, tabManager.tabs.count > 1)
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasAbove, (workspaceIndex ?? 0) > 0)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasBelow,
                (workspaceIndex ?? tabManager.tabs.count - 1) < tabManager.tabs.count - 1
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceCanMarkRead,
                notificationStore.canMarkWorkspaceRead(forTabIds: [workspace.id])
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceCanMarkUnread,
                notificationStore.canMarkWorkspaceUnread(forTabIds: [workspace.id])
            )
        }

        if let panelContext = focusedPanelContext {
            let workspace = panelContext.workspace
            let panelId = panelContext.panelId
            let panelIsTerminal = panelContext.panel.panelType == .terminal
            let panelIsRemoteTerminal = workspace.isRemoteTerminalSurface(panelId)
            snapshot.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            snapshot.setString(CommandPaletteContextKeys.panelName, panelDisplayName(workspace: workspace, panelId: panelId, fallback: panelContext.panel.displayTitle))
            snapshot.setBool(CommandPaletteContextKeys.panelIsBrowser, panelContext.panel.panelType == .browser)
            if let browserPanel = panelContext.panel as? BrowserPanel {
                snapshot.setBool(CommandPaletteContextKeys.panelBrowserFocusModeActive, browserPanel.isBrowserFocusModeActive)
            }
            // Markdown zoom only affects the rendered preview, so don't surface
            // the zoom commands when the panel is in raw text-edit mode.
            snapshot.setBool(
                CommandPaletteContextKeys.panelIsMarkdown,
                (panelContext.panel as? MarkdownPanel)?.displayMode == .preview
            )
            snapshot.setBool(
                CommandPaletteContextKeys.panelBrowserOmnibarVisible,
                (panelContext.panel as? BrowserPanel)?.isOmnibarVisible ?? true
            )
            snapshot.setBool(CommandPaletteContextKeys.panelIsTerminal, panelIsTerminal)
            snapshot.setBool(CommandPaletteContextKeys.panelHasPane, workspace.paneId(forPanelId: panelId) != nil)
            let fallbackForkableSnapshot = workspace.restoredAgentSnapshotsByPanelId[panelId]
            snapshot.setBool(
                CommandPaletteContextKeys.panelHasForkableAgent,
                Self.commandPalettePanelHasForkableAgent(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    fallbackSnapshot: fallbackForkableSnapshot,
                    isRemoteTerminal: panelIsRemoteTerminal
                )
            )
            snapshot.setBool(CommandPaletteContextKeys.panelHasCustomName, workspace.panelCustomTitles[panelId] != nil)
            snapshot.setBool(CommandPaletteContextKeys.panelShouldPin, !workspace.isPanelPinned(panelId))
            snapshot.setBool(CommandPaletteContextKeys.panelCanMoveToNewWorkspace, workspace.panels.count > 1)
            let hasUnread = workspace.manualUnreadPanelIds.contains(panelId) ||
                workspace.restoredUnreadPanelIds.contains(panelId) ||
                notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId)
            snapshot.setBool(CommandPaletteContextKeys.panelHasUnread, hasUnread)

            if panelIsTerminal {
                let availableTargets = terminalOpenTargets ?? TerminalDirectoryOpenTarget.availableTargets()
                for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
                    snapshot.setBool(
                        CommandPaletteContextKeys.terminalOpenTargetAvailable(target),
                        availableTargets.contains(target)
                    )
                }
            }
        }

        if case .updateAvailable = updateViewModel.effectiveState {
            snapshot.setBool(CommandPaletteContextKeys.updateHasAvailable, true)
        }

        return snapshot
    }

    /// Search keywords for the "Mobile Connect" command palette entry.
    ///
    /// Kept as a single source of truth so the contribution and its behavioral
    /// test agree on what queries (e.g. `ios`, `ipados`) must surface the
    /// command. These are platform/technical terms that read the same across
    /// locales, so they are not localized.
    static let commandPaletteMobileConnectKeywords: [String] = [
        "mobile", "connect", "pair", "pairing", "device",
        "ios", "ipados", "iphone", "ipad", "phone", "tablet", "qr",
    ]

    func sanitizeCmuxConfigPaletteText(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(text.unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commandPaletteCmuxConfigIssueCommandID(_ issue: CmuxConfigIssue) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in issue.id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "palette.cmuxConfig.issue.\(String(hash, radix: 16))"
    }

    func commandPaletteWorkspaceColorCommandID(_ colorName: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in colorName.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "palette.workspaceColor.\(String(hash, radix: 16))"
    }

    func commandPaletteExtensionSidebarCommandID(_ providerId: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in providerId.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "palette.extensionSidebar.\(String(hash, radix: 16))"
    }

    func commandPaletteCmuxConfigIssueTitle(_ issue: CmuxConfigIssue) -> String {
        switch issue.kind {
        case .schemaError:
            return String(
                localized: "command.cmuxConfig.issue.schemaError.title",
                defaultValue: "cmux.json Schema Error"
            )
        default:
            return String(
                localized: "command.cmuxConfig.issue.warning.title",
                defaultValue: "cmux.json Configuration Warning"
            )
        }
    }

    func commandPaletteCmuxConfigIssueSubtitle(_ issue: CmuxConfigIssue) -> String {
        let rawPath = issue.sourcePath.map {
            NSString(string: $0).abbreviatingWithTildeInPath
        } ?? issue.settingName
        let path = sanitizeCmuxConfigPaletteText(rawPath)
        let detail = sanitizeCmuxConfigPaletteText(commandPaletteCmuxConfigIssueDetail(issue))
        guard !detail.isEmpty else { return path }
        let format = String(
            localized: "command.cmuxConfig.issue.subtitle",
            defaultValue: "%@: %@"
        )
        return String(format: format, path, detail)
    }

    private func commandPaletteCmuxConfigIssueDetail(_ issue: CmuxConfigIssue) -> String {
        switch issue.kind {
        case .schemaError:
            let format = String(
                localized: "command.cmuxConfig.issue.schemaError.detail",
                defaultValue: "%@"
            )
            let fallback = String(
                localized: "command.cmuxConfig.issue.schemaError.fallback",
                defaultValue: "Invalid cmux.json"
            )
            return String(format: format, issue.message ?? fallback)
        case .newWorkspaceActionNotFound:
            let format = String(localized: "command.cmuxConfig.issue.newWorkspaceActionNotFound.detail", defaultValue: "%@ references missing action '%@'")
            return String(format: format, issue.settingName, issue.commandName ?? "")
        case .newWorkspaceCommandNotFound:
            let format = String(
                localized: "command.cmuxConfig.issue.newWorkspaceCommandNotFound.detail",
                defaultValue: "%@ references missing command '%@'"
            )
            return String(format: format, issue.settingName, issue.commandName ?? "")
        case .newWorkspaceCommandRequiresWorkspace:
            let format = String(
                localized: "command.cmuxConfig.issue.newWorkspaceCommandRequiresWorkspace.detail",
                defaultValue: "%@ '%@' must reference a workspace command"
            )
            return String(format: format, issue.settingName, issue.commandName ?? "")
        }
    }

}
