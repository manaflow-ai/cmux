import Foundation

struct CommandPaletteSettingToggleDescriptor: Sendable {
    let commandId: String
    let settingsKey: String
    let title: @Sendable () -> String
    let sectionTitle: @Sendable () -> String
    let keywords: [String]
    let isOn: @Sendable (UserDefaults) -> Bool
    let setOn: @Sendable (Bool, UserDefaults, NotificationCenter) -> Void
    let isAvailable: @Sendable (UserDefaults) -> Bool

    init(
        commandId: String,
        settingsKey: String,
        title: @escaping @Sendable () -> String,
        sectionTitle: @escaping @Sendable () -> String,
        keywords: [String],
        defaultValue: Bool,
        defaultsKey: String,
        isAvailable: @escaping @Sendable (UserDefaults) -> Bool = { _ in true },
        didSet: @escaping @Sendable (Bool, UserDefaults, NotificationCenter) -> Void = { _, _, _ in }
    ) {
        self.commandId = commandId
        self.settingsKey = settingsKey
        self.title = title
        self.sectionTitle = sectionTitle
        self.keywords = keywords
        self.isOn = { defaults in
            if defaults.object(forKey: defaultsKey) == nil {
                return defaultValue
            }
            return defaults.bool(forKey: defaultsKey)
        }
        self.setOn = { newValue, defaults, notificationCenter in
            defaults.set(newValue, forKey: defaultsKey)
            didSet(newValue, defaults, notificationCenter)
        }
        self.isAvailable = isAvailable
    }

    init(
        commandId: String,
        settingsKey: String,
        title: @escaping @Sendable () -> String,
        sectionTitle: @escaping @Sendable () -> String,
        keywords: [String],
        isOn: @escaping @Sendable (UserDefaults) -> Bool,
        setOn: @escaping @Sendable (Bool, UserDefaults, NotificationCenter) -> Void,
        isAvailable: @escaping @Sendable (UserDefaults) -> Bool = { _ in true }
    ) {
        self.commandId = commandId
        self.settingsKey = settingsKey
        self.title = title
        self.sectionTitle = sectionTitle
        self.keywords = keywords
        self.isOn = isOn
        self.setOn = setOn
        self.isAvailable = isAvailable
    }

    func commandTitle(defaults: UserDefaults = .standard) -> String {
        let format = isOn(defaults)
            ? String(localized: "command.toggleSetting.disableTitle", defaultValue: "Disable %@")
            : String(localized: "command.toggleSetting.enableTitle", defaultValue: "Enable %@")
        return String.localizedStringWithFormat(format, title())
    }

    func commandSubtitle(defaults: UserDefaults = .standard) -> String {
        let state = isOn(defaults)
            ? String(localized: "command.toggleSetting.state.on", defaultValue: "On")
            : String(localized: "command.toggleSetting.state.off", defaultValue: "Off")
        let format = String(localized: "command.toggleSetting.subtitle", defaultValue: "%@ • %@")
        return String.localizedStringWithFormat(format, sectionTitle(), state)
    }

    func toggle(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        guard isAvailable(defaults) else { return }
        setOn(!isOn(defaults), defaults, notificationCenter)
    }
}

enum CommandPaletteSettingsToggleCommands {
    static let commandIdPrefix = "palette.toggleSetting."

    static func descriptor(commandId: String) -> CommandPaletteSettingToggleDescriptor? {
        descriptors.first { $0.commandId == commandId }
    }

    static let descriptors: [CommandPaletteSettingToggleDescriptor] = {
        let app: @Sendable () -> String = { String(localized: "settings.section.app", defaultValue: "App") }
        let terminal: @Sendable () -> String = { String(localized: "settings.section.terminal", defaultValue: "Terminal") }
        let sidebar: @Sendable () -> String = {
            String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar")
        }
        let beta: @Sendable () -> String = {
            String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features")
        }
        let automation: @Sendable () -> String = {
            String(localized: "settings.section.automation", defaultValue: "Automation")
        }
        let browser: @Sendable () -> String = { String(localized: "settings.section.browser", defaultValue: "Browser") }
        let browserImport: @Sendable () -> String = {
            String(localized: "settings.section.browserImport", defaultValue: "Browser Import")
        }
        let globalHotkey: @Sendable () -> String = {
            String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey")
        }
        let sidebarDetailsAvailable: @Sendable (UserDefaults) -> Bool = { defaults in
            !SidebarWorkspaceDetailSettings.hidesAllDetails(defaults: defaults)
        }
        let sidebarPullRequestLinksAvailable: @Sendable (UserDefaults) -> Bool = { defaults in
            sidebarDetailsAvailable(defaults)
                && SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: defaults)
                && SidebarPullRequestClickabilitySettings.isClickable(defaults: defaults)
        }
        let sidebarPortLinksAvailable: @Sendable (UserDefaults) -> Bool = { defaults in
            sidebarDetailsAvailable(defaults)
                && SidebarWorkspaceDetailDefaults.boolValue(
                    defaults: defaults,
                    key: SidebarWorkspaceDetailDefaults.showPortsKey,
                    defaultValue: SidebarWorkspaceDetailDefaults.showPorts
                )
        }

        return [
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "workspaceInheritWorkingDirectory",
                settingsKey: "app.workspaceInheritWorkingDirectory",
                title: {
                    String(
                        localized: "settings.app.workspaceInheritWorkingDirectory",
                        defaultValue: "Inherit Workspace Working Directory"
                    )
                },
                sectionTitle: app,
                keywords: ["app.workspaceInheritWorkingDirectory", "workspace", "working", "directory", "cwd", "inherit"],
                defaultValue: WorkspaceWorkingDirectoryInheritanceSettings.defaultValue,
                defaultsKey: WorkspaceWorkingDirectoryInheritanceSettings.key
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "keepWorkspaceOpenWhenClosingLastSurface",
                settingsKey: "app.keepWorkspaceOpenWhenClosingLastSurface",
                title: {
                    String(
                        localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut",
                        defaultValue: "Keep Workspace Open When Closing Last Surface"
                    )
                },
                sectionTitle: app,
                keywords: ["app.keepWorkspaceOpenWhenClosingLastSurface", "close", "last", "surface", "pane", "workspace"],
                isOn: { defaults in !LastSurfaceCloseShortcutSettings.closesWorkspace(defaults: defaults) },
                setOn: { newValue, defaults, _ in
                    defaults.set(!newValue, forKey: LastSurfaceCloseShortcutSettings.key)
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "focusPaneOnFirstClick",
                settingsKey: "app.focusPaneOnFirstClick",
                title: {
                    String(localized: "settings.app.paneFirstClickFocus", defaultValue: "Focus Pane on First Click")
                },
                sectionTitle: app,
                keywords: ["app.focusPaneOnFirstClick", "pane", "focus", "click", "activation", "mouse"],
                defaultValue: PaneFirstClickFocusSettings.defaultEnabled,
                defaultsKey: PaneFirstClickFocusSettings.enabledKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "openSupportedFilesInCmux",
                settingsKey: "app.openSupportedFilesInCmux",
                title: {
                    String(
                        localized: "settings.app.openSupportedFilesInCmux",
                        defaultValue: "Open Supported Files in cmux"
                    )
                },
                sectionTitle: app,
                keywords: [
                    "app.openSupportedFilesInCmux",
                    "cmd",
                    "click",
                    "file",
                    "preview",
                    "pdf",
                    "image",
                    "audio",
                    "video",
                    "quicklook",
                    "quick",
                    "look",
                    "editor",
                    "external",
                ],
                defaultValue: CmdClickSupportedFileRouteSettings.defaultValue,
                defaultsKey: CmdClickSupportedFileRouteSettings.key,
                didSet: { _, _, notificationCenter in
                    CmdClickSupportedFileRouteSettings.notifyDidChange(notificationCenter: notificationCenter)
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "openMarkdownInCmuxViewer",
                settingsKey: "app.openMarkdownInCmuxViewer",
                title: {
                    String(
                        localized: "settings.app.openMarkdownInCmuxViewer",
                        defaultValue: "Open Markdown in cmux Viewer"
                    )
                },
                sectionTitle: app,
                keywords: ["app.openMarkdownInCmuxViewer", "markdown", "md", "viewer", "preview", "file"],
                defaultValue: CmdClickMarkdownRouteSettings.defaultValue,
                defaultsKey: CmdClickMarkdownRouteSettings.key
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "iMessageMode",
                settingsKey: "app.iMessageMode",
                title: {
                    String(localized: "settings.app.iMessageMode", defaultValue: "iMessage Mode")
                },
                sectionTitle: app,
                keywords: ["app.iMessageMode", "imessage", "message", "chat", "prompt", "agent", "workspace", "reorder"],
                defaultValue: IMessageModeSettings.defaultValue,
                defaultsKey: IMessageModeSettings.key
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "reorderOnNotification",
                settingsKey: "app.reorderOnNotification",
                title: {
                    String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification")
                },
                sectionTitle: app,
                keywords: ["app.reorderOnNotification", "notification", "reorder", "workspace", "unread", "sort"],
                defaultValue: WorkspaceAutoReorderSettings.defaultValue,
                defaultsKey: WorkspaceAutoReorderSettings.key
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "dockBadge",
                settingsKey: "notifications.dockBadge",
                title: {
                    String(localized: "settings.app.dockBadge", defaultValue: "Dock Badge")
                },
                sectionTitle: app,
                keywords: ["notifications.dockBadge", "dock", "badge", "notification", "unread", "count"],
                defaultValue: NotificationBadgeSettings.defaultDockBadgeEnabled,
                defaultsKey: NotificationBadgeSettings.dockBadgeEnabledKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "menuBarOnly",
                settingsKey: "app.menuBarOnly",
                title: {
                    String(localized: "settings.app.menuBarOnly", defaultValue: "Menu Bar Only")
                },
                sectionTitle: app,
                keywords: ["app.menuBarOnly", "menu", "bar", "dock", "cmd-tab", "app", "switcher"],
                defaultValue: MenuBarOnlySettings.defaultMenuBarOnly,
                defaultsKey: MenuBarOnlySettings.menuBarOnlyKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showInMenuBar",
                settingsKey: "notifications.showInMenuBar",
                title: {
                    String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar")
                },
                sectionTitle: app,
                keywords: ["notifications.showInMenuBar", "menu", "bar", "status", "tray", "extra"],
                defaultValue: MenuBarExtraSettings.defaultShowInMenuBar,
                defaultsKey: MenuBarExtraSettings.showInMenuBarKey,
                isAvailable: { defaults in !MenuBarOnlySettings.isEnabled(defaults: defaults) }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "unreadPaneRing",
                settingsKey: "notifications.unreadPaneRing",
                title: {
                    String(localized: "settings.notifications.paneRing.title", defaultValue: "Unread Pane Ring")
                },
                sectionTitle: app,
                keywords: ["notifications.unreadPaneRing", "notification", "unread", "pane", "ring", "outline"],
                defaultValue: NotificationPaneRingSettings.defaultEnabled,
                defaultsKey: NotificationPaneRingSettings.enabledKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "paneFlash",
                settingsKey: "notifications.paneFlash",
                title: {
                    String(localized: "settings.notifications.paneFlash.title", defaultValue: "Pane Flash")
                },
                sectionTitle: app,
                keywords: ["notifications.paneFlash", "notification", "pane", "flash", "highlight", "pulse"],
                defaultValue: NotificationPaneFlashSettings.defaultEnabled,
                defaultsKey: NotificationPaneFlashSettings.enabledKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "sendAnonymousTelemetry",
                settingsKey: "app.sendAnonymousTelemetry",
                title: {
                    String(localized: "settings.app.telemetry", defaultValue: "Send anonymous telemetry")
                },
                sectionTitle: app,
                keywords: ["app.sendAnonymousTelemetry", "telemetry", "analytics", "crash", "reports", "privacy"],
                defaultValue: TelemetrySettings.defaultSendAnonymousTelemetry,
                defaultsKey: TelemetrySettings.sendAnonymousTelemetryKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "warnBeforeQuit",
                settingsKey: "app.confirmQuit",
                title: {
                    String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit")
                },
                sectionTitle: app,
                keywords: ["app.confirmQuit", "app.warnBeforeQuit", "warn", "quit", "confirmation", "cmd-q", "exit"],
                isOn: { defaults in QuitWarningSettings.isEnabled(defaults: defaults) },
                setOn: { newValue, defaults, _ in
                    QuitWarningSettings.setEnabled(newValue, defaults: defaults)
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "warnBeforeClosingTab",
                settingsKey: "app.warnBeforeClosingTab",
                title: {
                    String(localized: "settings.app.warnBeforeClosingTab", defaultValue: "Warn Before Closing Tab")
                },
                sectionTitle: app,
                keywords: ["app.warnBeforeClosingTab", "warn", "close", "tab", "confirmation", "cmd-w"],
                defaultValue: CloseTabWarningSettings.defaultWarnBeforeClosingTab,
                defaultsKey: CloseTabWarningSettings.warnBeforeClosingTabKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "warnBeforeClosingTabXButton",
                settingsKey: "app.warnBeforeClosingTabXButton",
                title: {
                    String(
                        localized: "settings.app.warnBeforeClosingTabXButton",
                        defaultValue: "Warn Before Tab Close Button"
                    )
                },
                sectionTitle: app,
                keywords: [
                    "app.warnBeforeClosingTabXButton",
                    "warn",
                    "close",
                    "tab",
                    "x",
                    "button",
                    "confirmation",
                ],
                defaultValue: CloseTabWarningSettings.defaultWarnBeforeClosingTabXButton,
                defaultsKey: CloseTabWarningSettings.warnBeforeClosingTabXButtonKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "hideTabCloseButton",
                settingsKey: "app.hideTabCloseButton",
                title: {
                    String(localized: "settings.app.hideTabCloseButton", defaultValue: "Hide Tab Close Button")
                },
                sectionTitle: app,
                keywords: ["app.hideTabCloseButton", "hide", "close", "tab", "x", "button"],
                defaultValue: CloseTabWarningSettings.defaultHideTabCloseButton,
                defaultsKey: CloseTabWarningSettings.hideTabCloseButtonKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "renameSelectsExistingName",
                settingsKey: "app.renameSelectsExistingName",
                title: {
                    String(localized: "settings.app.renameSelectsName", defaultValue: "Rename Selects Existing Name")
                },
                sectionTitle: app,
                keywords: ["app.renameSelectsExistingName", "rename", "select", "name", "title", "command", "palette"],
                defaultValue: CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus,
                defaultsKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "commandPaletteSearchesAllSurfaces",
                settingsKey: "app.commandPaletteSearchesAllSurfaces",
                title: {
                    String(
                        localized: "settings.app.commandPaletteSearchAllSurfaces",
                        defaultValue: "Command Palette Searches All Surfaces"
                    )
                },
                sectionTitle: app,
                keywords: ["app.commandPaletteSearchesAllSurfaces", "command", "palette", "search", "surfaces", "workspace"],
                defaultValue: CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces,
                defaultsKey: CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "terminalShowScrollBar",
                settingsKey: "terminal.showScrollBar",
                title: {
                    String(localized: "settings.terminal.scrollBar", defaultValue: "Show Terminal Scroll Bar")
                },
                sectionTitle: terminal,
                keywords: ["terminal.showScrollBar", "terminal", "scroll", "scrollbar", "scrollback"],
                defaultValue: TerminalScrollBarSettings.defaultShowScrollBar,
                defaultsKey: TerminalScrollBarSettings.showScrollBarKey,
                didSet: { _, _, notificationCenter in
                    TerminalScrollBarSettings.notifyDidChange(notificationCenter: notificationCenter)
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "autoResumeAgentSessions",
                settingsKey: "terminal.autoResumeAgentSessions",
                title: {
                    String(
                        localized: "settings.terminal.agentAutoResume",
                        defaultValue: "Resume Agent Sessions on Reopen"
                    )
                },
                sectionTitle: terminal,
                keywords: ["terminal.autoResumeAgentSessions", "terminal", "agent", "resume", "sessions", "reopen", "restore"],
                isOn: { defaults in AgentSessionAutoResumeSettings.isEnabled(defaults: defaults) },
                setOn: { newValue, defaults, notificationCenter in
                    AgentSessionAutoResumeSettings.setEnabled(
                        newValue,
                        defaults: defaults,
                        notificationCenter: notificationCenter
                    )
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "agentHibernation",
                settingsKey: "terminal.agentHibernation.enabled",
                title: {
                    String(localized: "settings.terminal.agentHibernation", defaultValue: "Agent Hibernation")
                },
                sectionTitle: terminal,
                keywords: [
                    "terminal.agentHibernation.enabled",
                    "terminal",
                    "agent",
                    "hibernation",
                    "hibernate",
                    "suspend",
                    "claude",
                    "codex",
                    "opencode",
                    "idle",
                ],
                isOn: { defaults in AgentHibernationSettings.isEnabled(defaults: defaults) },
                setOn: { newValue, defaults, notificationCenter in
                    AgentHibernationSettings.setValues(
                        enabled: newValue,
                        defaults: defaults,
                        notificationCenter: notificationCenter
                    )
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "hideAllSidebarDetails",
                settingsKey: "sidebar.hideAllDetails",
                title: {
                    String(localized: "settings.app.hideAllSidebarDetails", defaultValue: "Hide All Sidebar Details")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.hideAllDetails", "sidebar", "hide", "details", "compact", "title"],
                defaultValue: SidebarWorkspaceDetailSettings.defaultHideAllDetails,
                defaultsKey: SidebarWorkspaceDetailSettings.hideAllDetailsKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "wrapWorkspaceTitlesInSidebar",
                settingsKey: "sidebar.wrapWorkspaceTitles",
                title: {
                    String(
                        localized: "settings.app.wrapWorkspaceTitles",
                        defaultValue: "Wrap Workspace Titles in Sidebar"
                    )
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.wrapWorkspaceTitles", "sidebar", "workspace", "title", "wrap", "pr", "pull", "request"],
                defaultValue: SidebarWorkspaceTitleWrapSettings.defaultWrap,
                defaultsKey: SidebarWorkspaceTitleWrapSettings.key
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showWorkspaceDescriptionInSidebar",
                settingsKey: "sidebar.showWorkspaceDescription",
                title: {
                    String(
                        localized: "settings.app.showWorkspaceDescription",
                        defaultValue: "Show Workspace Description in Sidebar"
                    )
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.showWorkspaceDescription", "sidebar", "workspace", "description", "notes"],
                defaultValue: SidebarWorkspaceDetailSettings.defaultShowWorkspaceDescription,
                defaultsKey: SidebarWorkspaceDetailSettings.showWorkspaceDescriptionKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "sidebarBranchVerticalLayout",
                settingsKey: "sidebar.branchLayout",
                title: {
                    String(localized: "settings.app.sidebarBranchLayout", defaultValue: "Sidebar Branch Layout")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.branchLayout", "sidebar", "branch", "layout", "vertical", "inline", "directory"],
                defaultValue: SidebarBranchLayoutSettings.defaultVerticalLayout,
                defaultsKey: SidebarBranchLayoutSettings.key,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showNotificationMessageInSidebar",
                settingsKey: "sidebar.showNotificationMessage",
                title: {
                    String(
                        localized: "settings.app.showNotificationMessage",
                        defaultValue: "Show Notification Message in Sidebar"
                    )
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.showNotificationMessage", "sidebar", "notification", "message", "latest", "unread"],
                defaultValue: SidebarWorkspaceDetailSettings.defaultShowNotificationMessage,
                defaultsKey: SidebarWorkspaceDetailSettings.showNotificationMessageKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showBranchDirectoryInSidebar",
                settingsKey: "sidebar.showBranchDirectory",
                title: {
                    String(localized: "settings.app.showBranchDirectory", defaultValue: "Show Branch + Directory in Sidebar")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.showBranchDirectory", "sidebar", "branch", "directory", "cwd", "path", "repo"],
                defaultValue: SidebarWorkspaceDetailDefaults.showBranchDirectory,
                defaultsKey: SidebarWorkspaceDetailDefaults.showBranchDirectoryKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showPullRequestsInSidebar",
                settingsKey: "sidebar.showPullRequests",
                title: {
                    String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.showPullRequests", "sidebar", "pull", "request", "pr", "review", "github"],
                defaultValue: SidebarWorkspaceDetailDefaults.showPullRequests,
                defaultsKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "watchGitStatusInSidebar",
                settingsKey: "sidebar.watchGitStatus",
                title: {
                    String(localized: "settings.app.watchGitStatus", defaultValue: "Watch Git Status in Sidebar")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.watchGitStatus", "sidebar", "git", "status", "branch", "watcher", "index", "lock"],
                defaultValue: SidebarWorkspaceDetailDefaults.watchGitStatus,
                defaultsKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "makeSidebarPullRequestsClickable",
                settingsKey: "sidebar.makePullRequestsClickable",
                title: {
                    String(
                        localized: "settings.app.makeSidebarPullRequestClickable",
                        defaultValue: "Make Sidebar PR Clickable"
                    )
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.makePullRequestsClickable", "sidebar", "pull", "request", "pr", "click", "link"],
                defaultValue: SidebarPullRequestClickabilitySettings.defaultClickable,
                defaultsKey: SidebarPullRequestClickabilitySettings.key,
                isAvailable: { defaults in
                    sidebarDetailsAvailable(defaults)
                        && SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: defaults)
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "openSidebarPullRequestLinksInCmuxBrowser",
                settingsKey: "sidebar.openPullRequestLinksInCmuxBrowser",
                title: {
                    String(
                        localized: "settings.app.openSidebarPRLinks",
                        defaultValue: "Open Sidebar PR Links in cmux Browser"
                    )
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.openPullRequestLinksInCmuxBrowser", "sidebar", "pull", "request", "pr", "browser", "link"],
                defaultValue: BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser,
                defaultsKey: BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey,
                isAvailable: sidebarPullRequestLinksAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "openSidebarPortLinksInCmuxBrowser",
                settingsKey: "sidebar.openPortLinksInCmuxBrowser",
                title: {
                    String(
                        localized: "settings.app.openSidebarPortLinks",
                        defaultValue: "Open Sidebar Port Links in cmux Browser"
                    )
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.openPortLinksInCmuxBrowser", "sidebar", "port", "localhost", "browser", "link"],
                defaultValue: BrowserLinkOpenSettings.defaultOpenSidebarPortLinksInCmuxBrowser,
                defaultsKey: BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey,
                isAvailable: sidebarPortLinksAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showSSHInSidebar",
                settingsKey: "sidebar.showSSH",
                title: {
                    String(localized: "settings.app.showSSH", defaultValue: "Show SSH in Sidebar")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.showSSH", "sidebar", "ssh", "remote", "host", "target"],
                defaultValue: SidebarWorkspaceDetailDefaults.showSSH,
                defaultsKey: SidebarWorkspaceDetailDefaults.showSSHKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showPortsInSidebar",
                settingsKey: "sidebar.showPorts",
                title: {
                    String(localized: "settings.app.showPorts", defaultValue: "Show Listening Ports in Sidebar")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.showPorts", "sidebar", "ports", "localhost", "server", "url"],
                defaultValue: SidebarWorkspaceDetailDefaults.showPorts,
                defaultsKey: SidebarWorkspaceDetailDefaults.showPortsKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showLogInSidebar",
                settingsKey: "sidebar.showLog",
                title: {
                    String(localized: "settings.app.showLog", defaultValue: "Show Latest Log in Sidebar")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.showLog", "sidebar", "log", "status", "latest", "message"],
                defaultValue: SidebarWorkspaceDetailDefaults.showLog,
                defaultsKey: SidebarWorkspaceDetailDefaults.showLogKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showProgressInSidebar",
                settingsKey: "sidebar.showProgress",
                title: {
                    String(localized: "settings.app.showProgress", defaultValue: "Show Progress in Sidebar")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.showProgress", "sidebar", "progress", "bar", "status"],
                defaultValue: SidebarWorkspaceDetailDefaults.showProgress,
                defaultsKey: SidebarWorkspaceDetailDefaults.showProgressKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showCustomMetadataInSidebar",
                settingsKey: "sidebar.showCustomMetadata",
                title: {
                    String(localized: "settings.app.showMetadata", defaultValue: "Show Custom Metadata in Sidebar")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.showCustomMetadata", "sidebar", "metadata", "meta", "custom", "status"],
                defaultValue: SidebarWorkspaceDetailDefaults.showCustomMetadata,
                defaultsKey: SidebarWorkspaceDetailDefaults.showCustomMetadataKey,
                isAvailable: sidebarDetailsAvailable
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "rightSidebarDock",
                settingsKey: "betaFeatures.dock",
                title: {
                    String(localized: "settings.betaFeatures.dock", defaultValue: "Dock")
                },
                sectionTitle: beta,
                keywords: ["betaFeatures.dock", "dock", "right", "sidebar", "beta", "terminal", "controls"],
                defaultValue: RightSidebarBetaFeatureSettings.defaultDockEnabled,
                defaultsKey: RightSidebarBetaFeatureSettings.dockEnabledKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "claudeCodeIntegration",
                settingsKey: "automation.claudeCodeIntegration",
                title: {
                    String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration")
                },
                sectionTitle: automation,
                keywords: ["automation.claudeCodeIntegration", "claude", "code", "hooks", "agent", "integration"],
                defaultValue: ClaudeCodeIntegrationSettings.defaultHooksEnabled,
                defaultsKey: ClaudeCodeIntegrationSettings.hooksEnabledKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "suppressSubagentNotifications",
                settingsKey: "automation.suppressSubagentNotifications",
                title: {
                    String(
                        localized: "settings.automation.suppressSubagentNotifications",
                        defaultValue: "Suppress Subagent Notifications"
                    )
                },
                sectionTitle: automation,
                keywords: [
                    "automation.suppressSubagentNotifications",
                    "subagent",
                    "nested",
                    "agent",
                    "codex",
                    "claude",
                    "notifications",
                    "hooks",
                ],
                defaultValue: AgentSubagentNotificationSettings.defaultSuppressNotifications,
                defaultsKey: AgentSubagentNotificationSettings.suppressNotificationsKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "cursorIntegration",
                settingsKey: "automation.cursorIntegration",
                title: {
                    String(localized: "settings.automation.cursor", defaultValue: "Cursor Integration")
                },
                sectionTitle: automation,
                keywords: ["automation.cursorIntegration", "cursor", "hooks", "agent", "integration"],
                defaultValue: CursorIntegrationSettings.defaultHooksEnabled,
                defaultsKey: CursorIntegrationSettings.hooksEnabledKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "geminiIntegration",
                settingsKey: "automation.geminiIntegration",
                title: {
                    String(localized: "settings.automation.gemini", defaultValue: "Gemini CLI Integration")
                },
                sectionTitle: automation,
                keywords: ["automation.geminiIntegration", "gemini", "hooks", "agent", "integration"],
                defaultValue: GeminiIntegrationSettings.defaultHooksEnabled,
                defaultsKey: GeminiIntegrationSettings.hooksEnabledKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "browserSearchSuggestions",
                settingsKey: "browser.showSearchSuggestions",
                title: {
                    String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions")
                },
                sectionTitle: browser,
                keywords: ["browser.showSearchSuggestions", "browser", "search", "suggestions", "autocomplete", "address", "bar"],
                defaultValue: BrowserSearchSettings.defaultSearchSuggestionsEnabled,
                defaultsKey: BrowserSearchSettings.searchSuggestionsEnabledKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "openTerminalLinksInCmuxBrowser",
                settingsKey: "browser.openTerminalLinksInCmuxBrowser",
                title: {
                    String(
                        localized: "settings.browser.openTerminalLinks",
                        defaultValue: "Open Terminal Links in cmux Browser"
                    )
                },
                sectionTitle: browser,
                keywords: ["browser.openTerminalLinksInCmuxBrowser", "browser", "terminal", "links", "url", "click"],
                defaultValue: BrowserLinkOpenSettings.defaultOpenTerminalLinksInCmuxBrowser,
                defaultsKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "interceptTerminalOpenCommandInCmuxBrowser",
                settingsKey: "browser.interceptTerminalOpenCommandInCmuxBrowser",
                title: {
                    String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal")
                },
                sectionTitle: browser,
                keywords: ["browser.interceptTerminalOpenCommandInCmuxBrowser", "browser", "terminal", "open", "http", "https", "intercept"],
                isOn: { defaults in
                    if defaults.object(forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey) != nil {
                        return defaults.bool(forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)
                    }
                    if defaults.object(forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey) != nil {
                        return defaults.bool(forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
                    }
                    return BrowserLinkOpenSettings.defaultInterceptTerminalOpenCommandInCmuxBrowser
                },
                setOn: { newValue, defaults, _ in
                    defaults.set(newValue, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "showBrowserImportHintOnBlankTabs",
                settingsKey: "browser.showImportHintOnBlankTabs",
                title: {
                    String(
                        localized: "settings.browser.import.hint.show",
                        defaultValue: "Show import hint on blank browser tabs"
                    )
                },
                sectionTitle: browserImport,
                keywords: ["browser.showImportHintOnBlankTabs", "browser", "import", "hint", "blank", "tabs", "onboarding"],
                defaultValue: BrowserImportHintSettings.defaultShowOnBlankTabs,
                defaultsKey: BrowserImportHintSettings.showOnBlankTabsKey,
                didSet: { newValue, defaults, _ in
                    if newValue {
                        defaults.set(false, forKey: BrowserImportHintSettings.dismissedKey)
                    }
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "systemWideHotkey",
                settingsKey: "globalHotkey.enable",
                title: {
                    String(localized: "settings.globalHotkey.enable", defaultValue: "Enable System-Wide Hotkey")
                },
                sectionTitle: globalHotkey,
                keywords: ["globalHotkey.enable", "global", "hotkey", "system", "wide", "show", "hide", "windows"],
                isOn: { defaults in SystemWideHotkeySettings.isEnabled(defaults: defaults) },
                setOn: { newValue, defaults, _ in
                    SystemWideHotkeySettings.setEnabled(newValue, defaults: defaults)
                }
            ),
        ]
    }()
}

extension ContentView {
    nonisolated static func commandPaletteSettingsToggleCommandContributions() -> [CommandPaletteCommandContribution] {
        CommandPaletteSettingsToggleCommands.descriptors.map { descriptor in
            CommandPaletteCommandContribution(
                commandId: descriptor.commandId,
                title: { _ in descriptor.commandTitle() },
                subtitle: { _ in descriptor.commandSubtitle() },
                keywords: descriptor.keywords + ["settings", "toggle", descriptor.settingsKey],
                when: { _ in descriptor.isAvailable(.standard) }
            )
        }
    }

    func registerSettingsToggleCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        for descriptor in CommandPaletteSettingsToggleCommands.descriptors {
            registry.register(commandId: descriptor.commandId) {
                descriptor.toggle()
            }
        }
    }
}
