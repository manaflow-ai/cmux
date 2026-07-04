import CmuxCommandPalette
import Foundation
import CmuxSettings

extension MenuBarOnlySettings {
    static let legacyCommandPaletteUsageKey = "commandPalette.commandUsage.v1"
    static let legacyCommandPaletteMenuBarOnlyCommandId = "palette.toggleSetting.menuBarOnly"

    static func normalizeLegacyStoredPreference(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: menuBarOnlyKey) != nil,
              defaults.bool(forKey: menuBarOnlyKey),
              defaults.object(forKey: explicitEnableKey) == nil else { return }
        setEnabled(!legacyCommandPaletteOneShotLikelyEnabledMenuBarOnly(defaults: defaults), defaults: defaults)
    }

    static func legacyCommandPaletteOneShotLikelyEnabledMenuBarOnly(defaults: UserDefaults = .standard) -> Bool {
        guard let data = defaults.data(forKey: legacyCommandPaletteUsageKey) else { return false }
        guard let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        guard history.count == 1, let entry = history[legacyCommandPaletteMenuBarOnlyCommandId] else { return false }
        guard let usage = entry as? [String: Any] else { return true }
        guard (usage["useCount"] as? NSNumber)?.intValue == 1 else { return false }
        return ((usage["lastUsedAt"] as? NSNumber)?.doubleValue ?? 0) > 0
    }
}

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
                defaultValue: SettingCatalog().app.workspaceInheritWorkingDirectory.defaultValue,
                defaultsKey: SettingCatalog().app.workspaceInheritWorkingDirectory.userDefaultsKey
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
                isOn: { defaults in
                    // Stored value carries close-on-last-surface semantics; the
                    // "Keep Workspace Open" toggle binds to its inverse.
                    !UserDefaultsSettingsClient(defaults: defaults)
                        .value(for: SettingCatalog().app.keepWorkspaceOpenWhenClosingLastSurface)
                },
                setOn: { newValue, defaults, _ in
                    UserDefaultsSettingsClient(defaults: defaults)
                        .set(!newValue, for: SettingCatalog().app.keepWorkspaceOpenWhenClosingLastSurface)
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
                defaultValue: AppCatalogSection().openSupportedFilesInCmux.defaultValue,
                defaultsKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey,
                didSet: { _, _, notificationCenter in
                    FileRouteSettingsStore(
                        defaults: .standard,
                        notificationCenter: notificationCenter
                    ).notifySupportedFileRouteDidChange()
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
                defaultValue: AppCatalogSection().openMarkdownInCmuxViewer.defaultValue,
                defaultsKey: AppCatalogSection().openMarkdownInCmuxViewer.userDefaultsKey,
                didSet: { _, _, notificationCenter in
                    FileRouteSettingsStore(
                        defaults: .standard,
                        notificationCenter: notificationCenter
                    ).notifyMarkdownRouteDidChange()
                }
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "fileEditorWordWrap",
                settingsKey: "fileEditor.wordWrap",
                title: {
                    String(localized: "settings.app.fileEditorWordWrap", defaultValue: "File Editor Word Wrap")
                },
                sectionTitle: app,
                keywords: ["fileEditor.wordWrap", "file", "editor", "word", "wrap", "soft", "reflow", "lines", "preview"],
                defaultValue: FilePreviewWordWrapSettings.defaultEnabled,
                defaultsKey: FilePreviewWordWrapSettings.key
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
                defaultValue: SettingCatalog().app.reorderOnNotification.defaultValue,
                defaultsKey: SettingCatalog().app.reorderOnNotification.userDefaultsKey
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
                defaultValue: AppCatalogSection().sendAnonymousTelemetry.defaultValue,
                defaultsKey: AppCatalogSection().sendAnonymousTelemetry.userDefaultsKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "warnBeforeQuit",
                settingsKey: "app.confirmQuit",
                title: {
                    String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit")
                },
                sectionTitle: app,
                keywords: ["app.confirmQuit", "app.warnBeforeQuit", "warn", "quit", "confirmation", "cmd-q", "exit"],
                isOn: { defaults in QuitConfirmationStore(defaults: defaults).isEnabled },
                setOn: { newValue, defaults, _ in
                    QuitConfirmationStore(defaults: defaults).setEnabled(newValue)
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
                defaultValue: AppCatalogSection().warnBeforeClosingTab.defaultValue,
                defaultsKey: AppCatalogSection().warnBeforeClosingTab.userDefaultsKey
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
                defaultValue: AppCatalogSection().warnBeforeClosingTabXButton.defaultValue,
                defaultsKey: AppCatalogSection().warnBeforeClosingTabXButton.userDefaultsKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "hideTabCloseButton",
                settingsKey: "app.hideTabCloseButton",
                title: {
                    String(localized: "settings.app.hideTabCloseButton", defaultValue: "Hide Tab Close Button")
                },
                sectionTitle: app,
                keywords: ["app.hideTabCloseButton", "hide", "close", "tab", "x", "button"],
                defaultValue: AppCatalogSection().hideTabCloseButton.defaultValue,
                defaultsKey: AppCatalogSection().hideTabCloseButton.userDefaultsKey
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "renameSelectsExistingName",
                settingsKey: "app.renameSelectsExistingName",
                title: {
                    String(localized: "settings.app.renameSelectsName", defaultValue: "Rename Selects Existing Name")
                },
                sectionTitle: app,
                keywords: ["app.renameSelectsExistingName", "rename", "select", "name", "title", "command", "palette"],
                defaultValue: AppCatalogSection().renameSelectsExistingName.defaultValue,
                defaultsKey: AppCatalogSection().renameSelectsExistingName.userDefaultsKey
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
                defaultValue: AppCatalogSection().commandPaletteSearchesAllSurfaces.defaultValue,
                defaultsKey: AppCatalogSection().commandPaletteSearchesAllSurfaces.userDefaultsKey
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
        ] + CommandPaletteSidebarSettingsToggles(commandIdPrefix: commandIdPrefix, sectionTitle: sidebar).descriptors() + [
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
                commandId: commandIdPrefix + "askWhereToSaveBrowserDownloads",
                settingsKey: "browser.askWhereToSaveDownloads",
                title: {
                    String(
                        localized: "settings.browser.askWhereToSaveDownloads",
                        defaultValue: "Ask Where to Save Downloads"
                    )
                },
                sectionTitle: browser,
                keywords: [
                    "browser.askWhereToSaveDownloads",
                    "browser",
                    "downloads",
                    "save",
                    "panel",
                    "folder",
                    "attachments",
                    "files",
                    "pdf",
                ],
                defaultValue: SettingCatalog().browser.askWhereToSaveDownloads.defaultValue,
                defaultsKey: SettingCatalog().browser.askWhereToSaveDownloads.userDefaultsKey
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
