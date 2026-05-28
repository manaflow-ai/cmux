import Foundation

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
}

enum AutomationSettings {
    static let portBaseKey = "cmuxPortBase"
    static let portRangeKey = "cmuxPortRange"
    static let defaultPortBase = 9100
    static let defaultPortRange = 10
}

extension CmuxSettingsFileStore {
    // Keep this in sync with the parser below and the web schema/docs. Settings UI rows
    // validate against this set so new persisted settings need an explicit cmux.json review.
    static let supportedSettingsJSONPaths: Set<String> = [
        "app.language",
        "app.appearance",
        "app.appIcon",
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
        "terminal.showScrollBar",
        "terminal.copyOnSelect",
        "terminal.autoResumeAgentSessions",
        "terminal.agentHibernation.enabled",
        "terminal.agentHibernation.idleSeconds",
        "terminal.agentHibernation.maxLiveTerminals",
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
        "automation.cursorIntegration",
        "automation.geminiIntegration",
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
        "shortcuts.bindings",
    ]
}
