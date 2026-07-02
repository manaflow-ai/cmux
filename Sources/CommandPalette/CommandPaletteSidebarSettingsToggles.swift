import CmuxSettings
import Foundation

extension CommandPaletteSettingsToggleCommands {
    static func sidebarDescriptors(
        sectionTitle sidebar: @escaping @Sendable () -> String
    ) -> [CommandPaletteSettingToggleDescriptor] {
        let sidebarDetailsAvailable: @Sendable (UserDefaults) -> Bool = { defaults in
            !UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.hideAllDetails)
        }
        let sidebarPullRequestLinksAvailable: @Sendable (UserDefaults) -> Bool = { defaults in
            sidebarDetailsAvailable(defaults)
                && SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: defaults)
                && UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.makePullRequestsClickable)
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
                commandId: commandIdPrefix + "hideAllSidebarDetails",
                settingsKey: "sidebar.hideAllDetails",
                title: {
                    String(localized: "settings.app.hideAllSidebarDetails", defaultValue: "Hide All Sidebar Details")
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.hideAllDetails", "sidebar", "hide", "details", "compact", "title"],
                defaultValue: SettingCatalog().sidebar.hideAllDetails.defaultValue,
                defaultsKey: SettingCatalog().sidebar.hideAllDetails.userDefaultsKey
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
                commandId: commandIdPrefix + "hideWorkspaceCloseButtonInSidebar",
                settingsKey: "sidebar.hideWorkspaceCloseButton",
                title: {
                    String(
                        localized: "settings.sidebar.hideWorkspaceCloseButton",
                        defaultValue: "Hide Workspace Close Button"
                    )
                },
                sectionTitle: sidebar,
                keywords: ["sidebar.hideWorkspaceCloseButton", "sidebar", "workspace", "close", "button", "x", "title", "width"],
                defaultValue: SettingCatalog().sidebar.hideWorkspaceCloseButton.defaultValue,
                defaultsKey: SettingCatalog().sidebar.hideWorkspaceCloseButton.userDefaultsKey
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
                defaultValue: SettingCatalog().sidebar.showWorkspaceDescription.defaultValue,
                defaultsKey: SettingCatalog().sidebar.showWorkspaceDescription.userDefaultsKey,
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
                defaultValue: SettingCatalog().sidebar.branchVerticalLayout.defaultValue,
                defaultsKey: SettingCatalog().sidebar.branchVerticalLayout.userDefaultsKey,
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
                defaultValue: SettingCatalog().sidebar.showNotificationMessage.defaultValue,
                defaultsKey: SettingCatalog().sidebar.showNotificationMessage.userDefaultsKey,
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
                defaultValue: SettingCatalog().sidebar.makePullRequestsClickable.defaultValue,
                defaultsKey: SettingCatalog().sidebar.makePullRequestsClickable.userDefaultsKey,
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
        ]
    }
}
