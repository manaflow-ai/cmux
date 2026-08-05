import AppKit
import CmuxCommandPalette
import CmuxSettings
import CmuxUpdater
import CmuxWorkspaces
import Foundation

/// Native command-palette actions that intentionally do not live in the macOS
/// menu bar. The menu graph remains the source for ordinary AppKit actions;
/// this catalog preserves context-sensitive and palette-only cmux commands.
@MainActor
final class MainWindowCommandPaletteSupplementalCatalog {
    private let windowId: UUID
    private let tabManager: TabManager
    private let updateViewModel: UpdateStateModel
    private let notificationStore: TerminalNotificationStore
    private let sidebarState: SidebarState
    private let sidebarSelectionState: SidebarSelectionState
    private let fileExplorerState: FileExplorerState
    private let cmuxConfigStore: CmuxConfigStore
    private let windowProvider: () -> NSWindow?
    private let openRightSidebarToolPane: (RightSidebarMode) -> Void

    init(
        windowId: UUID,
        tabManager: TabManager,
        updateViewModel: UpdateStateModel,
        notificationStore: TerminalNotificationStore,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState,
        fileExplorerState: FileExplorerState,
        cmuxConfigStore: CmuxConfigStore,
        windowProvider: @escaping () -> NSWindow?,
        openRightSidebarToolPane: @escaping (RightSidebarMode) -> Void
    ) {
        self.windowId = windowId
        self.tabManager = tabManager
        self.updateViewModel = updateViewModel
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
        self.sidebarSelectionState = sidebarSelectionState
        self.fileExplorerState = fileExplorerState
        self.cmuxConfigStore = cmuxConfigStore
        self.windowProvider = windowProvider
        self.openRightSidebarToolPane = openRightSidebarToolPane
    }

    func commands(startingAt rank: inout Int) -> [CommandPaletteCommand] {
        var commands: [CommandPaletteCommand] = []
        appendCreationCommands(to: &commands, rank: &rank)
        appendAccountAndCloudCommands(to: &commands, rank: &rank)
        appendRuntimeCommands(to: &commands, rank: &rank)
        appendSidebarCommands(to: &commands, rank: &rank)
        appendCanvasAndViewCommands(to: &commands, rank: &rank)
        appendWorkspaceCommands(to: &commands, rank: &rank)
        appendPanelCommands(to: &commands, rank: &rank)
        appendSavedLayoutCommands(to: &commands, rank: &rank)
        appendConfigurationCommands(to: &commands, rank: &rank)
        return commands
    }

    private func appendCommand(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int,
        id: String,
        title: String,
        subtitle: String,
        shortcutHint: String? = nil,
        keywords: [String],
        dismissOnRun: Bool = true,
        action: @escaping () -> Void
    ) {
        commands.append(CommandPaletteCommand(
            id: id,
            rank: rank,
            title: title,
            subtitle: subtitle,
            shortcutHint: shortcutHint,
            kindLabel: nil,
            keywords: keywords,
            dismissOnRun: dismissOnRun,
            action: action
        ))
        rank += 1
    }

    private func appendCreationCommands(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.newTerminalTab",
            title: String(localized: "command.newTerminalTab.title", defaultValue: "New Tab (Terminal)"),
            subtitle: String(localized: "command.newTerminalTab.subtitle", defaultValue: "Tab"),
            shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .newSurface)?.displayString,
            keywords: ["new", "terminal", "tab"]
        ) { [weak self] in
            guard let self else { return }
            if AppDelegate.shared?.executeConfiguredCmuxAction(
                id: CmuxSurfaceTabBarBuiltInAction.newTerminal.configID,
                tabManager: tabManager,
                preferredWindow: windowProvider()
            ) != true {
                tabManager.newSurface()
            }
        }

        if BrowserAvailabilitySettings.isEnabled() {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.newBrowserTab",
                title: String(localized: "command.newBrowserTab.title", defaultValue: "New Tab (Browser)"),
                subtitle: String(localized: "command.newBrowserTab.subtitle", defaultValue: "Tab"),
                shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .openBrowser)?.displayString,
                keywords: ["new", "browser", "tab", "web"]
            ) { [weak self] in
                guard let self else { return }
                if AppDelegate.shared?.executeConfiguredCmuxAction(
                    id: CmuxSurfaceTabBarBuiltInAction.newBrowser.configID,
                    tabManager: tabManager,
                    preferredWindow: windowProvider()
                ) != true {
                    _ = AppDelegate.shared?.openBrowserAndFocusAddressBar()
                }
            }
        }

        if CmuxFeatureFlags.shared.isAgentChatUIEnabled,
           BrowserAvailabilitySettings.isEnabled() {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.newAgentChat",
                title: String(localized: "command.newAgentChat.title", defaultValue: "New agent chat"),
                subtitle: String(localized: "command.newAgentChat.subtitle", defaultValue: "Agent Chat"),
                keywords: ["create", "new", "agent", "chat", "browser", "codex", "claude"]
            ) { [weak self] in
                guard let self else { return }
                if AppDelegate.shared?.executeConfiguredCmuxAction(
                    id: CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID,
                    tabManager: tabManager,
                    preferredWindow: windowProvider()
                ) != true {
                    NSSound.beep()
                }
            }
        }
    }

    private func appendAccountAndCloudCommands(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        if CmuxFeatureFlags.shared.isMobileConnectButtonEnabled {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.mobileConnect",
                title: String(localized: "command.mobileConnect.title", defaultValue: "Connect iPhone/iPad"),
                subtitle: String(localized: "command.mobileConnect.subtitle", defaultValue: "Mobile"),
                keywords: ["mobile", "connect", "pair", "pairing", "device", "ios", "ipados", "iphone", "ipad", "phone", "tablet", "qr"]
            ) { [weak self] in
                guard let self else { return }
                _ = AppDelegate.shared?.performMobileConnectWorkspaceAction(
                    tabManager: tabManager,
                    preferredWindow: windowProvider(),
                    debugSource: "palette.mobileConnect.native"
                )
            }
        }

        if let auth = AppDelegate.shared?.auth, !auth.accountFlow.isWorkingOnAuth {
            if auth.accountFlow.isAuthenticated {
                appendCommand(
                    to: &commands,
                    rank: &rank,
                    id: "palette.auth.signOut",
                    title: String(localized: "command.auth.signOut.title", defaultValue: "Sign Out"),
                    subtitle: String(localized: "command.auth.subtitle", defaultValue: "Account"),
                    keywords: ["account", "auth", "logout", "log out", "signout", "sign out"]
                ) {
                    Task { @MainActor in
                        await auth.accountFlow.signOut()
                    }
                }
            } else {
                appendCommand(
                    to: &commands,
                    rank: &rank,
                    id: "palette.auth.signIn",
                    title: String(localized: "command.auth.signIn.title", defaultValue: "Sign In"),
                    subtitle: String(localized: "command.auth.subtitle", defaultValue: "Account"),
                    keywords: ["account", "auth", "authenticate", "authentication", "login", "log in", "signin", "sign in"]
                ) {
                    auth.accountFlow.startSignIn()
                }
            }
        }

        if CmuxFeatureFlags.shared.isProUpgradeUIEnabled {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.pro.welcomeChecklist",
                title: String(localized: "command.pro.welcomeChecklist.title", defaultValue: "Welcome to cmux Pro"),
                subtitle: String(localized: "command.auth.subtitle", defaultValue: "Account"),
                keywords: ["pro", "welcome", "checklist", "onboarding", "cloud", "billing", "ios", "provider"]
            ) {
                ProWelcomeChecklistPresenter.present()
            }
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.pro.upgrade",
                title: String(localized: "command.pro.upgrade.title", defaultValue: "Upgrade to cmux Pro"),
                subtitle: String(localized: "command.auth.subtitle", defaultValue: "Account"),
                keywords: ["pro", "upgrade", "subscription", "billing", "plan", "pricing", "cloud", "purchase", "buy"]
            ) {
                ProUpgradePresenter.present()
            }
        }

        guard CmuxFeatureFlags.shared.isCloudVMUIEnabled else { return }
        let subtitle = String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud")
        let cloudCommands: [(String, String, [String], () -> Void)] = [
            ("palette.cloud.open", String(localized: "command.cloudVM.open.title", defaultValue: "Open Base"), ["base", "cloud", "vm", "ssh", "sshd", "open", "reconnect"], { _ = AppDelegate.shared?.performCloudVMAction(debugSource: "palette.cloud.open.native") }),
            ("palette.cloud.fork", String(localized: "command.cloudVM.fork.title", defaultValue: "Fork Current Cloud VM"), ["cloud", "vm", "fork", "clone", "branch"], { _ = AppDelegate.shared?.performCurrentCloudVMCommand(.fork, debugSource: "palette.cloud.fork.native") }),
            ("palette.cloud.snapshot", String(localized: "command.cloudVM.snapshot.title", defaultValue: "Checkpoint Current Cloud VM"), ["cloud", "vm", "snapshot", "checkpoint", "save"], { _ = AppDelegate.shared?.performCurrentCloudVMCommand(.snapshot, debugSource: "palette.cloud.snapshot.native") }),
            ("palette.cloud.restore", String(localized: "command.cloudVM.restore.title", defaultValue: "Restore Cloud VM From Checkpoint"), ["cloud", "vm", "restore", "snapshot", "checkpoint"], { _ = AppDelegate.shared?.performCloudVMRestoreCommand(debugSource: "palette.cloud.restore.native") }),
            ("palette.cloud.promoteTemplate", String(localized: "command.cloudVM.promoteTemplate.title", defaultValue: "Promote Current VM to Template"), ["cloud", "vm", "template", "promote", "snapshot"], { _ = AppDelegate.shared?.performCurrentCloudVMCommand(.promoteTemplate, debugSource: "palette.cloud.promoteTemplate.native") }),
            ("palette.cloud.status", String(localized: "command.cloudVM.status.title", defaultValue: "Show Cloud VM Status"), ["cloud", "vm", "status", "running", "paused"], { _ = AppDelegate.shared?.performCurrentCloudVMCommand(.status, debugSource: "palette.cloud.status.native") }),
            ("palette.cloud.ports", String(localized: "command.cloudVM.ports.title", defaultValue: "Show Cloud VM Ports"), ["cloud", "vm", "ports", "preview", "localhost"], { _ = AppDelegate.shared?.performCurrentCloudVMCommand(.ports, debugSource: "palette.cloud.ports.native") }),
            ("palette.cloud.tools", String(localized: "command.cloudVM.tools.title", defaultValue: "Inspect Cloud VM Tools"), ["cloud", "vm", "tools", "bootstrap", "zsh", "gh", "htop", "btop"], { _ = AppDelegate.shared?.performCurrentCloudVMCommand(.tools, debugSource: "palette.cloud.tools.native") }),
            ("palette.cloud.handoff", String(localized: "command.cloudVM.handoff.title", defaultValue: "Show Agent Handoff"), ["cloud", "vm", "agent", "handoff", "copy"], { _ = AppDelegate.shared?.performCurrentCloudVMCommand(.handoff, debugSource: "palette.cloud.handoff.native") }),
        ]
        for command in cloudCommands {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: command.0,
                title: command.1,
                subtitle: subtitle,
                keywords: command.2,
                action: command.3
            )
        }
    }

    private func appendRuntimeCommands(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        let cliInstalled = AppDelegate.shared?.isCmuxCLIInstalledInPATH() == true
        appendCommand(
            to: &commands,
            rank: &rank,
            id: cliInstalled ? "palette.uninstallCLI" : "palette.installCLI",
            title: cliInstalled
                ? String(localized: "command.uninstallCLI.title", defaultValue: "Shell Command: Uninstall 'cmux' from PATH")
                : String(localized: "command.installCLI.title", defaultValue: "Shell Command: Install 'cmux' in PATH"),
            subtitle: cliInstalled
                ? String(localized: "command.uninstallCLI.subtitle", defaultValue: "CLI")
                : String(localized: "command.installCLI.subtitle", defaultValue: "CLI"),
            keywords: cliInstalled
                ? ["uninstall", "remove", "cli", "path", "shell", "command", "symlink"]
                : ["install", "cli", "path", "shell", "command", "symlink"]
        ) {
            if cliInstalled {
                AppDelegate.shared?.uninstallCmuxCLIInPath(nil)
            } else {
                AppDelegate.shared?.installCmuxCLIInPath(nil)
            }
        }

        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.reopenPreviousSession",
            title: String(localized: "command.reopenPreviousSession.title", defaultValue: "Restore Previous App Launch"),
            subtitle: String(localized: "command.reopenPreviousSession.subtitle", defaultValue: "History"),
            keywords: ["reopen", "restore", "previous", "session", "launch", "resume"]
        ) {
            if AppDelegate.shared?.reopenPreviousSession() != true { NSSound.beep() }
        }

        if case .updateAvailable = updateViewModel.effectiveState {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.applyUpdateIfAvailable",
                title: String(localized: "command.applyUpdateIfAvailable.title", defaultValue: "Apply Update (If Available)"),
                subtitle: String(localized: "command.applyUpdateIfAvailable.subtitle", defaultValue: "Global"),
                keywords: ["apply", "install", "update", "available"]
            ) {
                AppDelegate.shared?.applyUpdateIfAvailable(nil)
            }
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.attemptUpdate",
            title: String(localized: "command.attemptUpdate.title", defaultValue: "Attempt Update"),
            subtitle: String(localized: "command.attemptUpdate.subtitle", defaultValue: "Global"),
            keywords: ["attempt", "check", "update", "upgrade", "release"]
        ) {
            AppDelegate.shared?.attemptUpdate(nil)
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.restartSocketListener",
            title: String(localized: "command.restartSocketListener.title", defaultValue: "Restart CLI Listener"),
            subtitle: String(localized: "command.restartSocketListener.subtitle", defaultValue: "Global"),
            keywords: ["restart", "socket", "listener", "cli", "cmux", "control"]
        ) {
            AppDelegate.shared?.restartSocketListener(nil)
        }

        let browserDisabled = BrowserAvailabilitySettings.isDisabled()
        appendCommand(
            to: &commands,
            rank: &rank,
            id: browserDisabled ? "palette.enableBrowser" : "palette.disableBrowser",
            title: browserDisabled
                ? String(localized: "command.enableBrowser.title", defaultValue: "Enable cmux Browser")
                : String(localized: "command.disableBrowser.title", defaultValue: "Disable cmux Browser"),
            subtitle: String(localized: "command.browserAvailability.subtitle", defaultValue: "Browser"),
            keywords: browserDisabled
                ? ["browser", "enable", "embedded", "open"]
                : ["browser", "disable", "external", "default", "open", "auth"]
        ) {
            BrowserAvailabilitySettings.setDisabled(!browserDisabled)
        }
    }

    private func appendSidebarCommands(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        for descriptor in CmuxExtensionSidebarSelection.descriptors {
            let title = CmuxExtensionSidebarSelection.localizedTitle(for: descriptor)
            let format = String(localized: "command.switchExtensionSidebar.title", defaultValue: "Sidebar: %@")
            appendCommand(
                to: &commands,
                rank: &rank,
                id: extensionSidebarCommandID(descriptor.id),
                title: String.localizedStringWithFormat(format, title),
                subtitle: String(localized: "command.switchExtensionSidebar.subtitle", defaultValue: "Choose Sidebar"),
                keywords: ["sidebar", "switch", "extension", title.lowercased()]
            ) {
                CmuxExtensionSidebarSelection.setProviderId(descriptor.id)
            }
        }

        for mode in RightSidebarMode.availableModes() {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: rightSidebarModeCommandID(mode),
                title: mode.shortcutAction?.label ?? mode.label,
                subtitle: String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar"),
                shortcutHint: mode.shortcutAction.flatMap(KeyboardShortcutSettings.shortcutIfBound(for:))?.displayString,
                keywords: ["right", "sidebar", "show", "switch", "focus", mode.rawValue]
            ) { [weak self] in
                guard let self else { return }
                if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                    mode: mode,
                    focusFirstItem: true,
                    preferredWindow: windowProvider()
                ) != true {
                    fileExplorerState.setVisible(true)
                    fileExplorerState.mode = mode
                }
            }
        }

        let paneModes: [(RightSidebarMode, String, String)] = [
            (.files, "palette.openFilesPane", String(localized: "command.openFilesPane.title", defaultValue: "Open Files as Pane")),
            (.find, "palette.openFindPane", String(localized: "command.openFindPane.title", defaultValue: "Open Find as Pane")),
            (.sessions, "palette.openVaultPane", String(localized: "command.openVaultPane.title", defaultValue: "Open Vault as Pane")),
        ]
        for (mode, id, title) in paneModes where mode.isAvailable() {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: id,
                title: title,
                subtitle: String(localized: "command.openRightSidebarToolAsPane.subtitle", defaultValue: "Pane"),
                keywords: ["open", "pane", "tool", "right", "sidebar", mode.rawValue, mode.label.lowercased()]
            ) { [weak self] in
                self?.openRightSidebarToolPane(mode)
            }
        }

        let matchesTerminal = UserDefaults.standard.bool(
            forKey: SidebarMatchTerminalBackgroundSettings.userDefaultsKey
        )
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.toggleMatchTerminalBackground",
            title: matchesTerminal
                ? String(localized: "command.disableMatchTerminalBackground.title", defaultValue: "Disable Match Terminal Background")
                : String(localized: "command.enableMatchTerminalBackground.title", defaultValue: "Enable Match Terminal Background"),
            subtitle: String(localized: "command.matchTerminalBackground.subtitle", defaultValue: "Sidebar"),
            keywords: ["match", "terminal", "background", "transparency", "sidebar", "surface", "chrome"]
        ) {
            UserDefaults.standard.set(
                !matchesTerminal,
                forKey: SidebarMatchTerminalBackgroundSettings.userDefaultsKey
            )
        }

        let mode = WorkspacePresentationModeSettings.mode()
        let minimal = mode == .minimal
        appendCommand(
            to: &commands,
            rank: &rank,
            id: minimal ? "palette.disableMinimalMode" : "palette.enableMinimalMode",
            title: minimal
                ? String(localized: "command.disableMinimalMode.title", defaultValue: "Disable Minimal Mode")
                : String(localized: "command.enableMinimalMode.title", defaultValue: "Enable Minimal Mode"),
            subtitle: String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout"),
            keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"]
        ) {
            UserDefaults.standard.set(
                (minimal ? WorkspacePresentationModeSettings.Mode.standard : .minimal).rawValue,
                forKey: WorkspacePresentationModeSettings.modeKey
            )
        }
    }

    private func appendCanvasAndViewCommands(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.triggerFlash",
            title: String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel"),
            subtitle: String(localized: "command.triggerFlash.subtitle", defaultValue: "View"),
            shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .triggerFlash)?.displayString,
            keywords: ["flash", "highlight", "focus", "panel"]
        ) { [weak tabManager] in
            tabManager?.triggerFocusFlash()
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.sleepyMode",
            title: String(localized: "command.sleepyMode.title", defaultValue: "Sleepy Mode"),
            subtitle: String(localized: "command.sleepyMode.subtitle", defaultValue: "View"),
            keywords: ["sleepy", "screensaver", "caffeinate", "keep awake", "do not sleep", "lock", "pets", "night"]
        ) {
            SleepyModeController.shared.activate()
        }

        guard let workspace = tabManager.selectedWorkspace,
              workspace.layoutMode == .canvas else { return }
        let subtitle = String(localized: "command.canvas.subtitle", defaultValue: "Canvas")
        let canvasCommands: [(String, KeyboardShortcutSettings.Action, [String])] = [
            ("palette.canvas.revealFocusedPane", .canvasRevealFocusedPane, ["canvas", "reveal", "scroll", "pane", "view"]),
            ("palette.canvas.zoomIn", .canvasZoomIn, ["canvas", "zoom", "in", "magnify", "bigger"]),
            ("palette.canvas.zoomOut", .canvasZoomOut, ["canvas", "zoom", "out", "shrink", "smaller"]),
            ("palette.canvas.zoomReset", .canvasZoomReset, ["canvas", "zoom", "reset", "actual", "size", "100"]),
            ("palette.canvas.alignLeft", .canvasAlignLeft, ["canvas", "align", "left", "edges"]),
            ("palette.canvas.alignRight", .canvasAlignRight, ["canvas", "align", "right", "edges"]),
            ("palette.canvas.alignTop", .canvasAlignTop, ["canvas", "align", "top", "edges"]),
            ("palette.canvas.alignBottom", .canvasAlignBottom, ["canvas", "align", "bottom", "edges"]),
            ("palette.canvas.equalizeWidths", .canvasEqualizeWidths, ["canvas", "equalize", "width", "same", "size"]),
            ("palette.canvas.equalizeHeights", .canvasEqualizeHeights, ["canvas", "equalize", "height", "same", "size"]),
            ("palette.canvas.distributeHorizontally", .canvasDistributeHorizontally, ["canvas", "distribute", "horizontal", "gap", "pack"]),
            ("palette.canvas.distributeVertically", .canvasDistributeVertically, ["canvas", "distribute", "vertical", "gap", "pack"]),
        ]
        for (id, shortcutAction, keywords) in canvasCommands {
            guard let canvasAction = shortcutAction.canvasAction else { continue }
            appendCommand(
                to: &commands,
                rank: &rank,
                id: id,
                title: shortcutAction.label,
                subtitle: subtitle,
                shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: shortcutAction)?.displayString,
                keywords: keywords
            ) {
                CanvasActionExecutor(workspace: workspace).perform(canvasAction)
            }
        }
    }

    private func appendSavedLayoutCommands(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        guard tabManager.selectedWorkspace != nil else { return }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.layout.saveCurrent",
            title: String(localized: "command.savedLayout.saveCurrent.title", defaultValue: "Save Layout as Template…"),
            subtitle: workspaceSubtitle,
            shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .saveLayoutTemplate)?.displayString,
            keywords: ["save", "layout", "template", "preset", "workspace", "split"]
        ) { [weak self] in
            guard let self else { return }
            AppDelegate.shared?.requestSavedLayoutSave(preferredWindow: windowProvider())
        }

        for layout in (try? SavedLayoutStore().list()) ?? [] {
            let format = String(localized: "command.savedLayout.openNamed.title", defaultValue: "New Workspace from Layout: %@")
            appendCommand(
                to: &commands,
                rank: &rank,
                id: savedLayoutOpenCommandID(layout.name),
                title: String.localizedStringWithFormat(format, layout.name),
                subtitle: String(localized: "command.savedLayout.subtitle", defaultValue: "Saved Layouts"),
                keywords: ["new", "open", "layout", "template", "preset", "workspace", "split", layout.name]
            ) { [weak tabManager] in
                do {
                    guard let resolved = try SavedLayoutStore().layout(named: layout.name) else {
                        NSSound.beep()
                        return
                    }
                    _ = tabManager?.openWorkspace(fromSavedLayout: resolved, cwdOverride: nil, focus: true)
                } catch {
                    NSSound.beep()
                }
            }
        }
    }

    private func appendWorkspaceCommands(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        guard let workspace = tabManager.selectedWorkspace else { return }

        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.markOldestUnreadAndJumpNext",
            title: String(
                localized: "command.markOldestUnreadAndJumpNext.title",
                defaultValue: "Mark as Oldest Unread and Jump to Next Latest Unread"
            ),
            subtitle: String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications"),
            shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .markOldestUnreadAndJumpNext)?.displayString,
            keywords: ["mark", "oldest", "unread", "jump", "next", "notification", "defer"]
        ) { [weak self] in
            AppDelegate.shared?.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
                preferredWindow: self?.windowProvider()
            )
        }

        if workspace.hasCustomTitle {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.clearWorkspaceName",
                title: String(localized: "command.clearWorkspaceName.title", defaultValue: "Clear Workspace Name"),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "name"]
            ) { [weak tabManager] in
                tabManager?.clearCustomTitle(tabId: workspace.id)
            }
        }

        if workspace.hasCustomDescription {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.clearWorkspaceDescription",
                title: String(localized: "command.clearWorkspaceDescription.title", defaultValue: "Clear Workspace Description"),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "description", "remove"]
            ) { [weak tabManager] in
                tabManager?.clearCustomDescription(tabId: workspace.id)
            }
        }

        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.resetWorkspaceColor",
            title: String(localized: "shortcut.resetWorkspaceColor.label", defaultValue: "Reset Workspace Color"),
            subtitle: workspaceSubtitle,
            keywords: ["workspace", "color", "reset", "clear", "palette"]
        ) { [weak tabManager] in
            tabManager?.applyWorkspaceColor(nil, toWorkspaceIds: [workspace.id])
        }
        for entry in WorkspaceTabColorSettings.palette() {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: stableCommandID(prefix: "palette.workspaceColor", value: entry.name),
                title: workspaceColorCommandTitle(entry.name),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "color", "palette", entry.name.lowercased()]
            ) { [weak tabManager] in
                tabManager?.applyWorkspacePaletteColor(
                    named: entry.name,
                    toWorkspaceIds: [workspace.id]
                )
            }
        }

        appendWorkspaceTodoCommands(
            workspace: workspace,
            to: &commands,
            rank: &rank
        )

        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.copyWorkspaceID",
            title: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
            subtitle: workspaceSubtitle,
            keywords: ["copy", "workspace", "id", "identifier"]
        ) {
            WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(
                [workspace.id],
                includeRefs: false
            )
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.copyWorkspaceIDAndRef",
            title: String(localized: "command.copyWorkspaceIDAndRef.title", defaultValue: "Copy Workspace ID and Ref"),
            subtitle: workspaceSubtitle,
            keywords: ["copy", "workspace", "id", "identifier", "ref", "reference"]
        ) {
            WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(
                [workspace.id],
                includeRefs: true
            )
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.copyWorkspaceLink",
            title: String(localized: "command.copyWorkspaceLink.title", defaultValue: "Copy Workspace Link"),
            subtitle: workspaceSubtitle,
            keywords: ["copy", "workspace", "link", "url", "deeplink", "deep link"]
        ) {
            WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makeWorkspaceLink(
                    workspaceId: workspace.stableId
                )
            )
        }

        if !workspace.sidebarPullRequestsInDisplayOrder().isEmpty {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.openWorkspacePullRequests",
                title: String(localized: "command.openWorkspacePRLinks.title", defaultValue: "Open All Workspace PR Links"),
                subtitle: workspaceSubtitle,
                keywords: ["pull", "request", "review", "merge", "pr", "mr", "open", "links", "workspace"]
            ) { [weak self] in
                if self?.openWorkspacePullRequests() != true { NSSound.beep() }
            }
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.openDiffViewer",
            title: String(localized: "command.openDiffViewer.title", defaultValue: "Open Diff Viewer"),
            subtitle: workspaceSubtitle,
            keywords: ["diff", "viewer", "changes", "git", "workspace"]
        ) { [weak tabManager] in
            guard let tabManager,
                  AppDelegate.shared?.openDiffViewerForFocusedWorkspace(for: tabManager) == true else {
                NSSound.beep()
                return
            }
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.openDirectoryDiffViewer",
            title: String(localized: "command.openDirectoryDiffViewer.title", defaultValue: "Open Directory Diff Viewer"),
            subtitle: workspaceSubtitle,
            keywords: ["directory", "folder", "diff", "viewer", "compare", "workspace"]
        ) { [weak tabManager] in
            guard let tabManager,
                  AppDelegate.shared?.openDirectoryDiffViewerForFocusedWorkspace(for: tabManager) == true else {
                NSSound.beep()
                return
            }
        }
    }

    private func appendWorkspaceTodoCommands(
        workspace: Workspace,
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        var registry = CommandPaletteHandlerRegistry()
        WorkspaceTodoPaletteCommands.registerHandlers(in: &registry, tabManager: tabManager)
        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        for contribution in WorkspaceTodoPaletteCommands.contributions(
            workspaceSubtitle: { [workspaceSubtitle] _ in workspaceSubtitle }
        ) where contribution.when(context) && contribution.enablement(context) {
            guard let action = registry.handler(for: contribution.commandId) else { continue }
            appendCommand(
                to: &commands,
                rank: &rank,
                id: contribution.commandId,
                title: contribution.title(context),
                subtitle: contribution.subtitle(context),
                shortcutHint: contribution.commandId == WorkspaceTodoPaletteCommands.markWorkspaceDoneCommandId
                    ? KeyboardShortcutSettings.shortcutIfBound(for: .markWorkspaceDone)?.displayString
                    : contribution.shortcutHint,
                keywords: contribution.keywords,
                dismissOnRun: contribution.dismissOnRun,
                action: action
            )
        }
        _ = workspace
    }

    private func appendPanelCommands(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        guard let context = focusedPanelContext else { return }
        let workspace = context.workspace
        let panelId = context.panelId
        let panel = context.panel
        let subtitle = panelSubtitle(context)

        if workspace.panelCustomTitles[panelId] != nil {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.clearTabName",
                title: String(localized: "command.clearTabName.title", defaultValue: "Clear Tab Name"),
                subtitle: subtitle,
                keywords: ["clear", "tab", "name"]
            ) {
                workspace.setPanelCustomTitle(panelId: panelId, title: nil)
            }
        }
        if workspace.panels.count > 1 {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.moveTabToNewWorkspace",
                title: String(localized: "command.moveTabToNewWorkspace.title", defaultValue: "Move Tab to New Workspace"),
                subtitle: subtitle,
                keywords: ["move", "tab", "workspace", "detach", "sidebar", "surface"]
            ) {
                guard AppDelegate.shared?.moveSurfaceToNewWorkspace(
                          panelId: panelId,
                          focus: true,
                          focusWindow: false
                      ) != nil else {
                    NSSound.beep()
                    return
                }
            }
        }
        let isPinned = workspace.isPanelPinned(panelId)
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.toggleTabPin",
            title: isPinned
                ? String(localized: "command.unpinTab.title", defaultValue: "Unpin Tab")
                : String(localized: "command.pinTab.title", defaultValue: "Pin Tab"),
            subtitle: subtitle,
            keywords: ["tab", "pin", "pinned"]
        ) {
            workspace.setPanelPinned(panelId: panelId, pinned: !isPinned)
        }
        let hasUnread = workspace.manualUnreadPanelIds.contains(panelId)
            || workspace.restoredUnreadPanelIds.contains(panelId)
            || notificationStore.sidebarUnread.hasUnreadNotification(
                forWorkspaceId: workspace.id,
                surfaceId: panelId
            )
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.toggleTabUnread",
            title: hasUnread
                ? String(localized: "command.markTabRead.title", defaultValue: "Mark Tab as Read")
                : String(localized: "command.markTabUnread.title", defaultValue: "Mark Tab as Unread"),
            subtitle: subtitle,
            keywords: ["tab", "read", "unread", "notification"]
        ) {
            if hasUnread {
                workspace.markPanelRead(panelId)
            } else {
                workspace.markPanelUnread(panelId)
            }
        }

        appendPanelIdentifierCommands(
            workspace: workspace,
            panelId: panelId,
            subtitle: subtitle,
            to: &commands,
            rank: &rank
        )

        if let browser = panel as? BrowserPanel {
            appendBrowserCommands(
                browser: browser,
                subtitle: subtitle,
                to: &commands,
                rank: &rank
            )
        }
        if let markdown = panel as? MarkdownPanel, markdown.displayMode == .preview {
            appendMarkdownCommands(
                subtitle: subtitle,
                to: &commands,
                rank: &rank
            )
        }
        if panel is TerminalPanel {
            appendTerminalCommands(
                workspace: workspace,
                panelId: panelId,
                subtitle: subtitle,
                to: &commands,
                rank: &rank
            )
        }
        if workspace.paneId(forPanelId: panelId) != nil {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.toggleFullWidthTab",
                title: String(localized: "command.toggleFullWidthTab.title", defaultValue: "Toggle Full Width Tab"),
                subtitle: String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout"),
                keywords: ["full", "width", "tab", "title", "header", "solo"]
            ) { [weak tabManager] in
                if tabManager?.toggleFocusedFullWidthTab() != true { NSSound.beep() }
            }
        }
    }

    private func appendPanelIdentifierCommands(
        workspace: Workspace,
        panelId: UUID,
        subtitle: String,
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        if let paneId = workspace.paneId(forPanelId: panelId)?.id {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.copyPaneID",
                title: String(localized: "command.copyPaneID.title", defaultValue: "Copy Pane ID"),
                subtitle: subtitle,
                keywords: ["copy", "pane", "split", "id", "identifier"]
            ) {
                WorkspaceSurfaceIdentifierClipboardText.copy(
                    WorkspaceSurfaceIdentifierClipboardText.makePane(paneId: paneId)
                )
            }
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.copyPaneLink",
                title: String(localized: "command.copyPaneLink.title", defaultValue: "Copy Pane Link"),
                subtitle: subtitle,
                keywords: ["copy", "pane", "split", "link", "url", "deeplink", "deep link"]
            ) {
                WorkspaceSurfaceIdentifierClipboardText.copy(
                    WorkspaceSurfaceIdentifierClipboardText.makePaneLink(
                        workspaceId: workspace.stableId,
                        paneId: paneId
                    )
                )
            }
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.copySurfaceID",
            title: String(localized: "command.copySurfaceID.title", defaultValue: "Copy Surface ID"),
            subtitle: subtitle,
            keywords: ["copy", "surface", "tab", "id", "identifier"]
        ) {
            WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makeSurface(surfaceId: panelId)
            )
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.copySurfaceLink",
            title: String(localized: "command.copySurfaceLink.title", defaultValue: "Copy Surface Link"),
            subtitle: subtitle,
            keywords: ["copy", "surface", "tab", "link", "url", "deeplink", "deep link"]
        ) {
            guard let panel = workspace.panels[panelId] else { return }
            WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                    workspaceId: workspace.stableId,
                    surfaceId: panel.stableSurfaceId
                )
            )
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.copyIdentifiers",
            title: String(localized: "terminalContextMenu.copyIdentifiers", defaultValue: "Copy IDs"),
            subtitle: subtitle,
            keywords: ["copy", "ids", "identifiers", "workspace", "pane", "surface", "ref", "reference"]
        ) {
            WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                    workspaceId: workspace.id,
                    paneId: workspace.paneId(forPanelId: panelId)?.id,
                    surfaceId: panelId,
                    includeRefs: true
                )
            )
        }
    }

    private func appendBrowserCommands(
        browser: BrowserPanel,
        subtitle: String,
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.browserOpenDefault",
            title: String(localized: "command.browserOpenDefault.title", defaultValue: "Open Current Page in Default Browser"),
            subtitle: subtitle,
            keywords: ["browser", "open", "default", "external", "safari", "chrome"]
        ) { [weak self] in
            if self?.openBrowserInDefaultBrowser(browser) != true { NSSound.beep() }
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.browserFocusAddressBar",
            title: String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar"),
            subtitle: subtitle,
            shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .focusBrowserAddressBar)?.displayString,
            keywords: ["browser", "address", "url", "omnibar", "focus", "location"]
        ) {
            _ = browser.requestAddressBarFocus(selectionIntent: .selectAll)
            NotificationCenter.default.post(name: .browserFocusAddressBar, object: browser.id)
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.browserToggleOmnibar",
            title: browser.isOmnibarVisible
                ? String(localized: "command.browserHideOmnibar.title", defaultValue: "Hide Browser Omnibar")
                : String(localized: "command.browserShowOmnibar.title", defaultValue: "Show Browser Omnibar"),
            subtitle: subtitle,
            keywords: ["browser", "omnibar", "address", "url", "bar", "hide", "show", "toggle"]
        ) { [weak tabManager] in
            if tabManager?.toggleOmnibarFocusedBrowser() != true { NSSound.beep() }
        }
        appendCommand(
            to: &commands,
            rank: &rank,
            id: "palette.browserDuplicateRight",
            title: String(localized: "command.browserDuplicateRight.title", defaultValue: "Duplicate Browser to the Right"),
            subtitle: String(localized: "command.browserDuplicateRight.subtitle", defaultValue: "Browser Layout"),
            keywords: ["browser", "duplicate", "clone", "split"]
        ) { [weak tabManager] in
            let url = browser.preferredURLStringForOmnibar().flatMap(URL.init(string:))
            _ = tabManager?.createBrowserSplit(direction: .right, url: url)
        }
    }

    private func appendMarkdownCommands(
        subtitle: String,
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        let actions: [(String, String, KeyboardShortcutSettings.Action, () -> Bool)] = [
            ("palette.markdownZoomIn", String(localized: "command.markdownZoomIn.title", defaultValue: "Zoom In"), .browserZoomIn, { [weak tabManager] in tabManager?.zoomInFocusedMarkdown() == true }),
            ("palette.markdownZoomOut", String(localized: "command.markdownZoomOut.title", defaultValue: "Zoom Out"), .browserZoomOut, { [weak tabManager] in tabManager?.zoomOutFocusedMarkdown() == true }),
            ("palette.markdownZoomReset", String(localized: "command.markdownZoomReset.title", defaultValue: "Actual Size"), .browserZoomReset, { [weak tabManager] in tabManager?.resetZoomFocusedMarkdown() == true }),
        ]
        for (id, title, shortcutAction, action) in actions {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: id,
                title: title,
                subtitle: subtitle,
                shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: shortcutAction)?.displayString,
                keywords: ["markdown", "preview", "zoom", "font", title.lowercased()]
            ) {
                if !action() { NSSound.beep() }
            }
        }
    }

    private func appendTerminalCommands(
        workspace: Workspace,
        panelId: UUID,
        subtitle: String,
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets
            where target.isAvailable() {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: target.commandPaletteCommandId,
                title: target.commandPaletteTitle,
                subtitle: subtitle,
                keywords: target.commandPaletteKeywords
            ) { [weak self] in
                if self?.openFocusedDirectory(in: target) != true { NSSound.beep() }
            }
        }
        if TerminalDirectoryOpenTarget.vscodeInline.isAvailable() {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.vscodeServeWebStop",
                title: String(localized: "command.vscodeServeWebStop.title", defaultValue: "Stop VS Code Inline Server"),
                subtitle: subtitle,
                keywords: ["vscode", "inline", "serve-web", "stop", "server"]
            ) {
                VSCodeServeWebController.shared.stop()
            }
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.vscodeServeWebRestart",
                title: String(localized: "command.vscodeServeWebRestart.title", defaultValue: "Restart VS Code Inline Server"),
                subtitle: subtitle,
                keywords: ["vscode", "inline", "serve-web", "restart", "server"]
            ) { [weak self] in
                if self?.restartInlineVSCodeServeWeb() != true { NSSound.beep() }
            }
        }

        let terminalActions: [(String, String, [String], KeyboardShortcutSettings.Action?, () -> Bool)] = [
            ("palette.terminalToggleTextBoxInput", String(localized: "command.terminalToggleTextBoxInput.title", defaultValue: "Toggle TextBox Input"), ["terminal", "textbox", "text", "box", "rich", "input", "prompt"], nil, { [weak tabManager] in tabManager?.toggleFocusedTerminalTextBox() == true }),
            ("palette.terminalFocusTextBoxInput", String(localized: "command.terminalFocusTextBoxInput.title", defaultValue: "Focus TextBox Input"), ["terminal", "textbox", "text", "box", "rich", "input", "prompt", "focus"], .focusTextBoxInput, { [weak tabManager] in tabManager?.focusFocusedTerminalTextBoxInputOrTerminal() == true }),
            ("palette.terminalAttachTextBoxFile", String(localized: "command.terminalAttachTextBoxFile.title", defaultValue: "Attach File to TextBox Input"), ["terminal", "textbox", "text", "box", "rich", "input", "attach", "file", "image"], .attachTextBoxFile, { [weak tabManager] in tabManager?.attachFileToFocusedTerminalTextBoxInput() == true }),
            ("palette.terminalClearScreenKeepScrollback", String(localized: "command.terminalClearScreenKeepScrollback.title", defaultValue: "Clear Screen (Keep Scrollback)"), ["terminal", "clear", "screen", "scrollback", "history", "keep", "preserve", "reset", "wipe", "cls", "erase"], .clearScreenKeepScrollback, { [weak tabManager] in tabManager?.clearFocusedTerminalKeepingScrollback() == true }),
        ]
        for (id, title, keywords, shortcutAction, action) in terminalActions {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: id,
                title: title,
                subtitle: subtitle,
                shortcutHint: shortcutAction.flatMap(KeyboardShortcutSettings.shortcutIfBound(for:))?.displayString,
                keywords: keywords
            ) {
                if !action() { NSSound.beep() }
            }
        }

        if workspace.bonsplitController.allPaneIds.count > 1 {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: "palette.toggleSplitZoom",
                title: String(localized: "command.toggleSplitZoom.title", defaultValue: "Toggle Pane Zoom"),
                subtitle: String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout"),
                shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .toggleSplitZoom)?.displayString,
                keywords: ["terminal", "pane", "split", "zoom", "maximize"]
            ) { [weak tabManager] in
                if tabManager?.toggleFocusedSplitZoom() != true { NSSound.beep() }
            }
        }

        let availability = workspace.forkAgentConversationContextMenuAvailability(
            forPanelId: panelId
        )
        if availability != .unsupported && availability != .notTerminalPanel {
            for destination in AgentConversationForkDestination.allCases {
                appendCommand(
                    to: &commands,
                    rank: &rank,
                    id: destination.commandPaletteCommandId,
                    title: destination.title,
                    subtitle: destination == .newWorkspace ? workspaceSubtitle : subtitle,
                    keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", destination.rawValue]
                ) {
                    Task { @MainActor in
                        await workspace.resolveForkAgentConversationContextMenuAvailability(
                            forPanelId: panelId
                        )
                        if await workspace.forkAgentConversationFromContextMenu(
                            fromPanelId: panelId,
                            destination: destination
                        ) != true {
                            NSSound.beep()
                        }
                    }
                }
            }
        }
    }

    private func appendConfigurationCommands(
        to commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        for issue in cmuxConfigStore.configurationIssues {
            appendCommand(
                to: &commands,
                rank: &rank,
                id: stableCommandID(prefix: "palette.cmuxConfig.issue", value: issue.id),
                title: configIssueTitle(issue),
                subtitle: configIssueSubtitle(issue),
                keywords: ["cmux", "config", "json", "schema", "error", "warning"]
            ) { [weak self] in
                self?.openConfigIssue(issue)
            }
        }
        let defaultSubtitle = String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json")
        for action in cmuxConfigStore.paletteCustomActions() {
            let title = sanitizePaletteText(action.title)
            let subtitle = action.subtitle
                .map(sanitizePaletteText)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? defaultSubtitle
            appendCommand(
                to: &commands,
                rank: &rank,
                id: action.id,
                title: title,
                subtitle: subtitle,
                shortcutHint: action.shortcut?.displayString,
                keywords: action.keywords
            ) { [weak self] in
                guard let self else { return }
                _ = CmuxConfigExecutor.execute(
                    action: action,
                    commands: cmuxConfigStore.loadedCommands,
                    commandSourcePaths: cmuxConfigStore.commandSourcePaths,
                    tabManager: tabManager,
                    baseCwd: tabManager.selectedWorkspace?.resolvedWorkingDirectory()
                        ?? FileManager.default.homeDirectoryForCurrentUser.path,
                    globalConfigPath: cmuxConfigStore.globalConfigPath
                )
            }
        }
    }

    private var workspaceSubtitle: String {
        let fallback = String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace")
        let name = tabManager.selectedWorkspace.map(workspaceDisplayName) ?? fallback
        return String(localized: "commandPalette.subtitle.workspaceWithName", defaultValue: "Workspace • \(name)")
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
            : title
    }

    private var focusedPanelContext: (
        workspace: Workspace,
        panelId: UUID,
        panel: any Panel
    )? {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    private func panelSubtitle(
        _ context: (workspace: Workspace, panelId: UUID, panel: any Panel)
    ) -> String {
        let custom = context.workspace.panelTitle(panelId: context.panelId)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = context.panel.displayTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = !custom.isEmpty
            ? custom
            : (fallback.isEmpty
                ? String(localized: "panel.displayName.fallback", defaultValue: "Tab")
                : fallback)
        return String(localized: "commandPalette.subtitle.tabWithName", defaultValue: "Tab • \(name)")
    }

    private func workspaceColorCommandTitle(_ paletteName: String) -> String {
        switch paletteName {
        case "Red":
            String(localized: "shortcut.setWorkspaceColorRed.label", defaultValue: "Workspace Color: Red")
        case "Crimson":
            String(localized: "shortcut.setWorkspaceColorCrimson.label", defaultValue: "Workspace Color: Crimson")
        case "Orange":
            String(localized: "shortcut.setWorkspaceColorOrange.label", defaultValue: "Workspace Color: Orange")
        case "Amber":
            String(localized: "shortcut.setWorkspaceColorAmber.label", defaultValue: "Workspace Color: Amber")
        case "Olive":
            String(localized: "shortcut.setWorkspaceColorOlive.label", defaultValue: "Workspace Color: Olive")
        case "Green":
            String(localized: "shortcut.setWorkspaceColorGreen.label", defaultValue: "Workspace Color: Green")
        case "Teal":
            String(localized: "shortcut.setWorkspaceColorTeal.label", defaultValue: "Workspace Color: Teal")
        case "Aqua":
            String(localized: "shortcut.setWorkspaceColorAqua.label", defaultValue: "Workspace Color: Aqua")
        case "Blue":
            String(localized: "shortcut.setWorkspaceColorBlue.label", defaultValue: "Workspace Color: Blue")
        default:
            String(
                localized: "command.workspaceColor.named",
                defaultValue: "Workspace Color: \(paletteName)"
            )
        }
    }

    private func openWorkspacePullRequests() -> Bool {
        guard let workspace = tabManager.selectedWorkspace else { return false }
        let pullRequests = workspace.sidebarPullRequestsInDisplayOrder()
        guard !pullRequests.isEmpty else { return false }
        var openedCount = 0
        if BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser() {
            for pullRequest in pullRequests {
                if tabManager.openBrowser(url: pullRequest.url, insertAtEnd: true) != nil
                    || NSWorkspace.shared.open(pullRequest.url) {
                    openedCount += 1
                }
            }
        } else {
            for pullRequest in pullRequests where NSWorkspace.shared.open(pullRequest.url) {
                openedCount += 1
            }
        }
        return openedCount > 0
    }

    private func openBrowserInDefaultBrowser(_ panel: BrowserPanel) -> Bool {
        guard let rawURL = panel.preferredURLStringForOmnibar(),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func openFocusedDirectory(in target: TerminalDirectoryOpenTarget) -> Bool {
        guard let directoryURL = focusedTerminalDirectoryURL() else { return false }
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
            return true
        case .vscodeInline:
            return AppDelegate.shared?.openDirectoryInInlineVSCode(
                directoryURL,
                tabManager: tabManager
            ) ?? false
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            NSWorkspace.shared.open(
                [directoryURL],
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        }
    }

    private func focusedTerminalDirectoryURL() -> URL? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let rawDirectory: String
        if let panelId = workspace.focusedPanelId {
            guard workspace.allowsLocalDirectoryFallback(panelId: panelId) else { return nil }
            rawDirectory = workspace.reportedPanelDirectory(panelId: panelId)
                ?? workspace.terminalPanel(for: panelId)?.requestedWorkingDirectory
                ?? (workspace.isRemoteWorkspace ? "" : workspace.currentDirectory)
        } else {
            rawDirectory = workspace.isRemoteWorkspace ? "" : workspace.currentDirectory
        }
        let path = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func restartInlineVSCodeServeWeb() -> Bool {
        guard let applicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL() else {
            return false
        }
        VSCodeServeWebController.shared.restart(vscodeApplicationURL: applicationURL) { url in
            if url == nil { NSSound.beep() }
        }
        return true
    }

    private func openConfigIssue(_ issue: CmuxConfigIssue) {
        guard let path = issue.sourcePath,
              FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        PreferredEditorService(defaults: .standard).open(URL(fileURLWithPath: path))
    }

    private func configIssueTitle(_ issue: CmuxConfigIssue) -> String {
        switch issue.kind {
        case .schemaError:
            String(localized: "command.cmuxConfig.issue.schemaError.title", defaultValue: "cmux.json Schema Error")
        default:
            String(localized: "command.cmuxConfig.issue.warning.title", defaultValue: "cmux.json Configuration Warning")
        }
    }

    private func configIssueSubtitle(_ issue: CmuxConfigIssue) -> String {
        let rawPath = issue.sourcePath.map {
            NSString(string: $0).abbreviatingWithTildeInPath
        } ?? issue.settingName
        let path = sanitizePaletteText(rawPath)
        let detail = sanitizePaletteText(configIssueDetail(issue))
        guard !detail.isEmpty else { return path }
        let format = String(localized: "command.cmuxConfig.issue.subtitle", defaultValue: "%@: %@")
        return String(format: format, path, detail)
    }

    private func configIssueDetail(_ issue: CmuxConfigIssue) -> String {
        switch issue.kind {
        case .schemaError:
            let format = String(localized: "command.cmuxConfig.issue.schemaError.detail", defaultValue: "%@")
            let fallback = String(localized: "command.cmuxConfig.issue.schemaError.fallback", defaultValue: "Invalid cmux.json")
            return String(format: format, issue.message ?? fallback)
        case .newWorkspaceActionNotFound:
            let format = String(localized: "command.cmuxConfig.issue.newWorkspaceActionNotFound.detail", defaultValue: "%@ references missing action '%@'")
            return String(format: format, issue.settingName, issue.commandName ?? "")
        case .newWorkspaceCommandNotFound:
            let format = String(localized: "command.cmuxConfig.issue.newWorkspaceCommandNotFound.detail", defaultValue: "%@ references missing command '%@'")
            return String(format: format, issue.settingName, issue.commandName ?? "")
        case .newWorkspaceCommandRequiresWorkspace:
            let format = String(localized: "command.cmuxConfig.issue.newWorkspaceCommandRequiresWorkspace.detail", defaultValue: "%@ '%@' must reference a workspace command")
            return String(format: format, issue.settingName, issue.commandName ?? "")
        }
    }

    private func sanitizePaletteText(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}",
        ]
        return String(text.unicodeScalars.filter { !dangerous.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extensionSidebarCommandID(_ descriptorID: String) -> String {
        stableCommandID(prefix: "palette.extensionSidebar", value: descriptorID)
    }

    private func savedLayoutOpenCommandID(_ name: String) -> String {
        let encodedName = Data(name.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "palette.layout.open.\(encodedName)"
    }

    private func stableCommandID(prefix: String, value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(prefix).\(String(hash, radix: 16))"
    }

    private func rightSidebarModeCommandID(_ mode: RightSidebarMode) -> String {
        switch mode {
        case .files: "palette.showRightSidebarFiles"
        case .find: "palette.showRightSidebarFind"
        case .sessions: "palette.showRightSidebarSessions"
        case .feed: "palette.showRightSidebarFeed"
        case .dock: "palette.showRightSidebarDock"
        case .customSidebar: "palette.showRightSidebarCustomSidebar"
        }
    }
}
