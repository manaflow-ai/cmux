import CmuxSettings
import Foundation

typealias RightSidebarWidthSettings = CmuxSettings.RightSidebarWidthSettings

enum SidebarWorkspaceDetailDefaults {
    static let showBranchDirectoryKey = "sidebarShowBranchDirectory"
    static let showPullRequestsKey = "sidebarShowPullRequest"
    static let watchGitStatusKey = "sidebarWatchGitStatus"
    static let showSSHKey = "sidebarShowSSH"
    static let showPortsKey = "sidebarShowPorts"
    static let showLogKey = "sidebarShowLog"
    static let showProgressKey = "sidebarShowProgress"
    static let showCustomMetadataKey = "sidebarShowStatusPills"

    static let showBranchDirectory = true
    static let showPullRequests = true
    static let watchGitStatus = true
    static let showSSH = true
    static let showPorts = true
    static let showLog = true
    static let showProgress = true
    static let showCustomMetadata = true
}

enum SidebarWorkspaceTitleWrapSettings {
    static let key = "sidebarWrapWorkspaceTitles"
    static let defaultWrap = false

    static func wraps(defaults: UserDefaults = .standard) -> Bool {
        SidebarWorkspaceDetailDefaults.boolValue(
            defaults: defaults,
            key: key,
            defaultValue: defaultWrap
        )
    }
}

extension SidebarWorkspaceDetailDefaults {
    static func boolValue(defaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    static func showPullRequestsValue(defaults: UserDefaults) -> Bool {
        boolValue(defaults: defaults, key: showPullRequestsKey, defaultValue: showPullRequests)
    }

    static func watchGitStatusValue(defaults: UserDefaults) -> Bool {
        boolValue(defaults: defaults, key: watchGitStatusKey, defaultValue: watchGitStatus)
    }

    static func pullRequestPollingEnabled(defaults: UserDefaults) -> Bool {
        watchGitStatusValue(defaults: defaults) && showPullRequestsValue(defaults: defaults)
    }
}

enum AutomationSettings {
    static let portBaseKey = "cmuxPortBase"
    static let portRangeKey = "cmuxPortRange"
    static let defaultPortBase = 9100
    static let defaultPortRange = 10
}

struct SettingsFileBooleanMapping {
    let jsonKey: String
    let defaultsKey: String
    let invalidPath: String?

    init(jsonKey: String, defaultsKey: String, invalidPath: String? = nil) {
        self.jsonKey = jsonKey
        self.defaultsKey = defaultsKey
        self.invalidPath = invalidPath
    }
}

struct SettingsFileStringMapping {
    let jsonKey: String
    let defaultsKey: String
}

struct SettingsFileStringArrayMapping {
    let jsonKey: String
    let defaultsKey: String
    let invalidPath: String
}

enum AppSettingsFileMapping {
    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(
            jsonKey: "workspaceInheritWorkingDirectory",
            defaultsKey: WorkspaceWorkingDirectoryInheritanceSettings.key,
            invalidPath: "app.workspaceInheritWorkingDirectory"
        ),
        .init(jsonKey: "focusPaneOnFirstClick", defaultsKey: PaneFirstClickFocusSettings.enabledKey),
        .init(
            jsonKey: "openSupportedFilesInCmux",
            defaultsKey: CmdClickSupportedFileRouteSettings.key
        ),
        .init(
            jsonKey: "openMarkdownInCmuxViewer",
            defaultsKey: CmdClickMarkdownRouteSettings.key
        ),
        .init(jsonKey: "reorderOnNotification", defaultsKey: WorkspaceAutoReorderSettings.key),
        .init(jsonKey: "iMessageMode", defaultsKey: IMessageModeSettings.key),
        .init(
            jsonKey: "sendAnonymousTelemetry",
            defaultsKey: TelemetrySettings.sendAnonymousTelemetryKey
        ),
        .init(
            jsonKey: "warnBeforeClosingTab",
            defaultsKey: CloseTabWarningSettings.warnBeforeClosingTabKey
        ),
        .init(
            jsonKey: "warnBeforeClosingTabXButton",
            defaultsKey: CloseTabWarningSettings.warnBeforeClosingTabXButtonKey
        ),
        .init(
            jsonKey: "hideTabCloseButton",
            defaultsKey: CloseTabWarningSettings.hideTabCloseButtonKey
        ),
        .init(
            jsonKey: "renameSelectsExistingName",
            defaultsKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey
        ),
        .init(
            jsonKey: "commandPaletteSearchesAllSurfaces",
            defaultsKey: CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey
        ),
    ]

    static let stringSettings: [SettingsFileStringMapping] = [
        .init(jsonKey: "preferredEditor", defaultsKey: PreferredEditorSettings.key),
    ]
}

enum NotificationSettingsFileMapping {
    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(jsonKey: "dockBadge", defaultsKey: NotificationBadgeSettings.dockBadgeEnabledKey),
        .init(jsonKey: "showInMenuBar", defaultsKey: MenuBarExtraSettings.showInMenuBarKey),
        .init(jsonKey: "unreadPaneRing", defaultsKey: NotificationPaneRingSettings.enabledKey),
        .init(jsonKey: "paneFlash", defaultsKey: NotificationPaneFlashSettings.enabledKey),
    ]

    static let stringSettings: [SettingsFileStringMapping] = [
        .init(jsonKey: "customSoundFilePath", defaultsKey: NotificationSoundSettings.customFilePathKey),
        .init(jsonKey: "command", defaultsKey: NotificationSoundSettings.customCommandKey),
    ]
}

enum TerminalSettingsFileMapping {
    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(
            jsonKey: "showScrollBar",
            defaultsKey: TerminalScrollBarSettings.showScrollBarKey,
            invalidPath: "terminal.showScrollBar"
        ),
        .init(
            jsonKey: "copyOnSelect",
            defaultsKey: TerminalCopyOnSelectSettings.copyOnSelectKey,
            invalidPath: "terminal.copyOnSelect"
        ),
        .init(
            jsonKey: "autoResumeAgentSessions",
            defaultsKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey,
            invalidPath: "terminal.autoResumeAgentSessions"
        ),
    ]
}

enum SidebarSettingsFileMapping {
    struct BooleanSetting {
        let jsonKey: String
        let defaultsKey: String
    }

    static let booleanSettings: [BooleanSetting] = [
        .init(
            jsonKey: "hideAllDetails",
            defaultsKey: SidebarWorkspaceDetailSettings.hideAllDetailsKey
        ),
        .init(
            jsonKey: "wrapWorkspaceTitles",
            defaultsKey: SidebarWorkspaceTitleWrapSettings.key
        ),
        .init(
            jsonKey: "showWorkspaceDescription",
            defaultsKey: SidebarWorkspaceDetailSettings.showWorkspaceDescriptionKey
        ),
        .init(
            jsonKey: "stackBranchDirectory",
            defaultsKey: SidebarBranchDirectoryStackedSettings.key
        ),
        .init(
            jsonKey: "pathLastSegmentOnly",
            defaultsKey: SidebarPathLastSegmentSettings.key
        ),
        .init(
            jsonKey: "showNotificationMessage",
            defaultsKey: SidebarWorkspaceDetailSettings.showNotificationMessageKey
        ),
        .init(
            jsonKey: "showBranchDirectory",
            defaultsKey: SidebarWorkspaceDetailDefaults.showBranchDirectoryKey
        ),
        .init(
            jsonKey: "showPullRequests",
            defaultsKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey
        ),
        .init(
            jsonKey: "watchGitStatus",
            defaultsKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey
        ),
        .init(
            jsonKey: "makePullRequestsClickable",
            defaultsKey: SidebarPullRequestClickabilitySettings.key
        ),
        .init(
            jsonKey: "openPullRequestLinksInCmuxBrowser",
            defaultsKey: BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey
        ),
        .init(
            jsonKey: "openPortLinksInCmuxBrowser",
            defaultsKey: BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey
        ),
        .init(jsonKey: "showSSH", defaultsKey: SidebarWorkspaceDetailDefaults.showSSHKey),
        .init(jsonKey: "showPorts", defaultsKey: SidebarWorkspaceDetailDefaults.showPortsKey),
        .init(jsonKey: "showLog", defaultsKey: SidebarWorkspaceDetailDefaults.showLogKey),
        .init(
            jsonKey: "showProgress",
            defaultsKey: SidebarWorkspaceDetailDefaults.showProgressKey
        ),
        .init(
            jsonKey: "showCustomMetadata",
            defaultsKey: SidebarWorkspaceDetailDefaults.showCustomMetadataKey
        ),
    ]

    static func branchLayoutStoredValue(_ rawValue: String) -> Bool? {
        switch rawValue {
        case "vertical":
            return true
        case "inline":
            return false
        default:
            return nil
        }
    }
}

enum AutomationSettingsFileMapping {
    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(jsonKey: "claudeCodeIntegration", defaultsKey: ClaudeCodeIntegrationSettings.hooksEnabledKey),
        .init(
            jsonKey: "suppressSubagentNotifications",
            defaultsKey: AgentSubagentNotificationSettings.suppressNotificationsKey
        ),
        .init(jsonKey: "ampIntegration", defaultsKey: AmpIntegrationSettings.hooksEnabledKey),
        .init(jsonKey: "cursorIntegration", defaultsKey: CursorIntegrationSettings.hooksEnabledKey),
        .init(jsonKey: "geminiIntegration", defaultsKey: GeminiIntegrationSettings.hooksEnabledKey),
        .init(jsonKey: "kiroIntegration", defaultsKey: KiroIntegrationSettings.hooksEnabledKey),
    ]

    static let stringSettings: [SettingsFileStringMapping] = [
        .init(jsonKey: "claudeBinaryPath", defaultsKey: ClaudeCodeIntegrationSettings.customClaudePathKey),
        .init(jsonKey: "ripgrepBinaryPath", defaultsKey: RipgrepIntegrationSettings.customRipgrepPathKey),
    ]
}

enum BrowserSettingsFileMapping {
    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(jsonKey: "showSearchSuggestions", defaultsKey: BrowserSearchSettings.searchSuggestionsEnabledKey),
        .init(jsonKey: "discardHiddenWebViews", defaultsKey: BrowserHiddenWebViewDiscardPolicy.enabledKey),
        .init(
            jsonKey: "openTerminalLinksInCmuxBrowser",
            defaultsKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey
        ),
        .init(
            jsonKey: "interceptTerminalOpenCommandInCmuxBrowser",
            defaultsKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey
        ),
        .init(jsonKey: "showImportHintOnBlankTabs", defaultsKey: BrowserImportHintSettings.showOnBlankTabsKey),
    ]

    static let stringSettings: [SettingsFileStringMapping] = [
        .init(jsonKey: "reactGrabVersion", defaultsKey: ReactGrabSettings.versionKey),
    ]

    static let stringArraySettings: [SettingsFileStringArrayMapping] = [
        .init(
            jsonKey: "hostsToOpenInEmbeddedBrowser",
            defaultsKey: BrowserLinkOpenSettings.browserHostWhitelistKey,
            invalidPath: "browser.hostsToOpenInEmbeddedBrowser"
        ),
        .init(
            jsonKey: "urlsToAlwaysOpenExternally",
            defaultsKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey,
            invalidPath: "browser.urlsToAlwaysOpenExternally"
        ),
        .init(
            jsonKey: "insecureHttpHostsAllowedInEmbeddedBrowser",
            defaultsKey: BrowserInsecureHTTPSettings.allowlistKey,
            invalidPath: "browser.insecureHttpHostsAllowedInEmbeddedBrowser"
        ),
    ]
}

extension CmuxSettingsFileStore {
    // Keep this in sync with the parser below and the web schema/docs. Settings UI rows
    // validate against this set so new persisted settings need an explicit cmux.json review.
    static let supportedSettingsJSONPaths: Set<String> = [
        "app.language",
        "app.appearance",
        "app.appIcon",
        "app.windowTitleTemplate",
        "app.menuBarOnly",
        "app.newWorkspacePlacement",
        "app.workspaceInheritWorkingDirectory",
        "app.minimalMode",
        "app.keepWorkspaceOpenWhenClosingLastSurface",
        "app.focusPaneOnFirstClick",
        "app.preferredEditor",
        "app.openSupportedFilesInCmux",
        "app.openMarkdownInCmuxViewer",
        "app.iMessageMode",
        "app.reorderOnNotification",
        "app.sendAnonymousTelemetry",
        "app.confirmQuit",
        "app.warnBeforeQuit",
        "app.warnBeforeClosingTab",
        "app.warnBeforeClosingTabXButton",
        "app.hideTabCloseButton",
        "app.renameSelectsExistingName",
        "app.commandPaletteSearchesAllSurfaces",
        "workspaceGroups.newWorkspacePlacement",
        "terminal.showScrollBar",
        "terminal.copyOnSelect",
        "terminal.autoResumeAgentSessions",
        "terminal.showTextBoxOnNewTerminals",
        "terminal.focusTextBoxOnNewTerminals",
        "terminal.agentHibernation.enabled",
        "terminal.agentHibernation.idleSeconds",
        "terminal.agentHibernation.maxLiveTerminals",
        "terminal.rendererRealization.enabled",
        "terminal.rendererRealization.idleSeconds",
        "terminal.rendererRealization.maxWarmRenderers",
        "terminal.textBoxMaxLines",
        "terminal.resumeCommands",
        "notifications.dockBadge",
        "notifications.showInMenuBar",
        "notifications.unreadPaneRing",
        "notifications.paneFlash",
        "notifications.sound",
        "notifications.customSoundFilePath",
        "notifications.command",
        "notifications.hooks",
        "notifications.hooksMode",
        "sidebar.hideAllDetails",
        "sidebar.wrapWorkspaceTitles",
        "sidebar.showWorkspaceDescription",
        "sidebar.branchLayout",
        "sidebar.stackBranchDirectory",
        "sidebar.pathLastSegmentOnly",
        "sidebar.showNotificationMessage",
        "sidebar.showBranchDirectory",
        "sidebar.showPullRequests",
        "sidebar.watchGitStatus",
        "sidebar.makePullRequestsClickable",
        "sidebar.openPullRequestLinksInCmuxBrowser",
        "sidebar.openPortLinksInCmuxBrowser",
        "sidebar.showSSH",
        "sidebar.showPorts",
        "sidebar.showLog",
        "sidebar.showProgress",
        "sidebar.showCustomMetadata",
        RightSidebarWidthSettings.settingsPath,
        "workspaceColors.indicatorStyle",
        "workspaceColors.selectionColor",
        "workspaceColors.notificationBadgeColor",
        "workspaceColors.colors",
        "workspaceColors.paletteOverrides",
        "workspaceColors.customColors",
        "sidebarAppearance.matchTerminalBackground",
        "sidebarAppearance.tintColor",
        "sidebarAppearance.lightModeTintColor",
        "sidebarAppearance.darkModeTintColor",
        "sidebarAppearance.tintOpacity",
        "automation.socketControlMode",
        "automation.socketPassword",
        "automation.claudeCodeIntegration",
        "automation.claudeBinaryPath",
        "automation.ripgrepBinaryPath",
        "automation.suppressSubagentNotifications",
        "automation.ampIntegration",
        "automation.cursorIntegration",
        "automation.geminiIntegration",
        "automation.kiroIntegration",
        "automation.kiroNotificationLevel",
        "automation.portBase",
        "automation.portRange",
        "browser.defaultSearchEngine",
        "browser.customSearchEngineName",
        "browser.customSearchEngineURLTemplate",
        "browser.showSearchSuggestions",
        "browser.theme",
        "browser.discardHiddenWebViews",
        "browser.hiddenWebViewDiscardDelaySeconds",
        "browser.openTerminalLinksInCmuxBrowser",
        "browser.interceptTerminalOpenCommandInCmuxBrowser",
        "browser.hostsToOpenInEmbeddedBrowser",
        "browser.urlsToAlwaysOpenExternally",
        "browser.insecureHttpHostsAllowedInEmbeddedBrowser",
        "browser.showImportHintOnBlankTabs",
        "browser.reactGrabVersion",
        "markdown.fontSize",
        "markdown.fontFamily",
        "markdown.maxWidth",
        "canvas.paneGap",
        "canvas.snappingEnabled",
        "fileEditor.wordWrap",
        "shortcuts.bindings",
    ]
}
