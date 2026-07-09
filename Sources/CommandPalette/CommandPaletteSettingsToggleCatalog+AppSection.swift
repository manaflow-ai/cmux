import CmuxCommandPalette
import CmuxNotifications
import CmuxSettings
import Foundation

extension CommandPaletteSettingsToggleCatalog {
    /// The App-section settings-toggle descriptors, in display order.
    ///
    /// Split out of `init()` for navigability. The localized titles and the
    /// `default`/`isOn`/`setOn`/`didSet` closures reach app-side
    /// `MenuBarExtraSettings`/`MenuBarOnlySettings`/notification settings, so this
    /// stays in the app target (it cannot move into `CmuxCommandPalette`).
    /// `commandIdPrefix` and the `app` section-title closure are passed in from
    /// `init()` so the descriptor bodies are byte-identical to the originals.
    static func appSectionDescriptors(
        commandIdPrefix: String,
        app: @escaping @Sendable () -> String
    ) -> [CommandPaletteSettingToggleDescriptor] {
        [
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
                defaultValue: NotificationDefaultsToggle.dockBadge.defaultValue,
                defaultsKey: NotificationDefaultsToggle.dockBadge.key
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
                defaultValue: NotificationDefaultsToggle.paneRing.defaultValue,
                defaultsKey: NotificationDefaultsToggle.paneRing.key
            ),
            CommandPaletteSettingToggleDescriptor(
                commandId: commandIdPrefix + "paneFlash",
                settingsKey: "notifications.paneFlash",
                title: {
                    String(localized: "settings.notifications.paneFlash.title", defaultValue: "Pane Flash")
                },
                sectionTitle: app,
                keywords: ["notifications.paneFlash", "notification", "pane", "flash", "highlight", "pulse"],
                defaultValue: NotificationDefaultsToggle.paneFlash.defaultValue,
                defaultsKey: NotificationDefaultsToggle.paneFlash.key
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
        ]
    }
}
