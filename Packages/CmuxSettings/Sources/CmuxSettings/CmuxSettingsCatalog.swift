import Foundation

public struct CmuxSettingsJSONPathDescriptor: Equatable, Hashable, Sendable {
    public let path: String
    public let section: String

    public init(path: String, section: String? = nil) {
        self.path = path
        self.section = section ?? path.split(separator: ".", maxSplits: 1).first.map(String.init) ?? path
    }
}

public enum CmuxSettingsCatalog {
    public static let currentSchemaVersion = 1

    public static let schemaURLString =
        "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json"

    public static func defaultPrimaryURL(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
    }

    public static func defaultLegacyURL(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    public static func defaultApplicationSupportLegacyURL(
        applicationSupportDirectoryURL: URL,
        releaseBundleIdentifier: String = "com.cmuxterm.app"
    ) -> URL {
        applicationSupportDirectoryURL
            .appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    public static let supportedJSONPathDescriptors: [CmuxSettingsJSONPathDescriptor] =
        supportedJSONPathValues.map { CmuxSettingsJSONPathDescriptor(path: $0) }

    public static let supportedJSONPaths: Set<String> = Set(supportedJSONPathValues)

    private static let supportedJSONPathValues: [String] = [
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
