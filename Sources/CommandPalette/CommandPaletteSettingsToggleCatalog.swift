import CmuxBrowser
import CmuxCommandPalette
import Foundation
import CmuxSettings

/// The curated set of settings-backed command-palette toggles.
///
/// A real value type whose stored `descriptors` are the catalog of toggles the
/// command palette exposes. The app-resolved localized format strings
/// (``toggleStrings``) stay here in the app bundle so `String(localized:)` binds
/// to the app's `Localizable.xcstrings` (resolving them inside `CmuxCommandPalette`
/// would drop non-English translations), then flow across the seam into each
/// descriptor's `commandTitle(strings:)`/`commandSubtitle(strings:)`.
struct CommandPaletteSettingsToggleCatalog {
    static let commandIdPrefix = "palette.toggleSetting."

    /// Every settings-toggle descriptor, in display order.
    let descriptors: [CommandPaletteSettingToggleDescriptor]

    /// App-resolved localized formats for toggle command titles/subtitles.
    ///
    /// Resolved here in the app bundle (not inside `CmuxCommandPalette`) so the
    /// Japanese translations are preserved, then passed to the descriptor's
    /// `commandTitle(strings:)`/`commandSubtitle(strings:)`.
    var toggleStrings: CommandPaletteSettingToggleStrings {
        CommandPaletteSettingToggleStrings(
            disableTitleFormat: String(
                localized: "command.toggleSetting.disableTitle",
                defaultValue: "Disable %@"
            ),
            enableTitleFormat: String(
                localized: "command.toggleSetting.enableTitle",
                defaultValue: "Enable %@"
            ),
            onState: String(localized: "command.toggleSetting.state.on", defaultValue: "On"),
            offState: String(localized: "command.toggleSetting.state.off", defaultValue: "Off"),
            subtitleFormat: String(localized: "command.toggleSetting.subtitle", defaultValue: "%@ • %@")
        )
    }

    func descriptor(commandId: String) -> CommandPaletteSettingToggleDescriptor? {
        descriptors.first { $0.commandId == commandId }
    }

    init() {
        let commandIdPrefix = Self.commandIdPrefix
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

        descriptors = Self.appSectionDescriptors(commandIdPrefix: commandIdPrefix, app: app) + [
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
                commandId: commandIdPrefix + "rendererRealization",
                settingsKey: "terminal.rendererRealization.enabled",
                title: {
                    String(
                        localized: "settings.terminal.rendererRealization",
                        defaultValue: "Reclaim Offscreen Terminal Memory"
                    )
                },
                sectionTitle: terminal,
                keywords: [
                    "terminal.rendererRealization.enabled",
                    "terminal",
                    "renderer",
                    "reclaim",
                    "offscreen",
                    "memory",
                    "iosurface",
                    "gpu",
                    "idle",
                ],
                isOn: { defaults in RendererRealizationSettings.isEnabled(defaults: defaults) },
                setOn: { newValue, defaults, notificationCenter in
                    RendererRealizationSettings.setValues(
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
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "rightSidebarFeed",
                settingsKey: "betaFeatures.feed",
                title: {
                    String(localized: "settings.betaFeatures.feed", defaultValue: "Feed")
                },
                sectionTitle: beta,
                keywords: ["betaFeatures.feed", "feed", "right", "sidebar", "beta", "agent", "decisions", "permissions"],
                defaultValue: RightSidebarBetaFeatureSettings.defaultFeedEnabled,
                defaultsKey: RightSidebarBetaFeatureSettings.feedEnabledKey
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
                defaultValue: IntegrationsCatalogSection().claudeCodeHooksEnabled.defaultValue,
                defaultsKey: IntegrationsCatalogSection().claudeCodeHooksEnabled.userDefaultsKey
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
                defaultValue: IntegrationsCatalogSection().suppressSubagentNotifications.defaultValue,
                defaultsKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "cursorIntegration",
                settingsKey: "automation.cursorIntegration",
                title: {
                    String(localized: "settings.automation.cursor", defaultValue: "Cursor Integration")
                },
                sectionTitle: automation,
                keywords: ["automation.cursorIntegration", "cursor", "hooks", "agent", "integration"],
                defaultValue: IntegrationsCatalogSection().cursorHooksEnabled.defaultValue,
                defaultsKey: IntegrationsCatalogSection().cursorHooksEnabled.userDefaultsKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "geminiIntegration",
                settingsKey: "automation.geminiIntegration",
                title: {
                    String(localized: "settings.automation.gemini", defaultValue: "Gemini CLI Integration")
                },
                sectionTitle: automation,
                keywords: ["automation.geminiIntegration", "gemini", "hooks", "agent", "integration"],
                defaultValue: IntegrationsCatalogSection().geminiHooksEnabled.defaultValue,
                defaultsKey: IntegrationsCatalogSection().geminiHooksEnabled.userDefaultsKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "kiroIntegration",
                settingsKey: "automation.kiroIntegration",
                title: {
                    String(localized: "settings.automation.kiro", defaultValue: "Kiro CLI Integration")
                },
                sectionTitle: automation,
                keywords: ["automation.kiroIntegration", "kiro", "cli", "hooks", "agent", "integration"],
                defaultValue: IntegrationsCatalogSection().kiroHooksEnabled.defaultValue,
                defaultsKey: IntegrationsCatalogSection().kiroHooksEnabled.userDefaultsKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "browserSearchSuggestions",
                settingsKey: "browser.showSearchSuggestions",
                title: {
                    String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions")
                },
                sectionTitle: browser,
                keywords: ["browser.showSearchSuggestions", "browser", "search", "suggestions", "autocomplete", "address", "bar"],
                defaultValue: BrowserSearchSettingsStore.defaultSearchSuggestionsEnabled,
                defaultsKey: BrowserSearchSettingsStore.searchSuggestionsEnabledKey
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
    }
}
