import CmuxSettings
import SwiftUI

/// **App** section — mirrors the legacy in-app section row-for-row
/// inside a single `SettingsCard`: Language, Appearance, App Icon,
/// New Workspace Placement, Inherit Working Directory, Minimal Mode,
/// Keep Workspace Open When Closing Last Surface, Focus Pane on
/// First Click, File Drops, Open Files With, Open Supported Files in
/// cmux, Terminal Config link, Open Markdown in cmux Viewer,
/// iMessage Mode, Reorder on Notification, Dock Badge, Menu Bar
/// Only, Show in Menu Bar, Unread Pane Ring, Pane Flash, Desktop
/// Notifications, Notification Sound, Notification Command, Send
/// anonymous telemetry, Warn Before Quit, Warn Before Closing Tab /
/// X Button / Hide Tab Close Button, Rename Selects Existing Name,
/// Command Palette Searches All Surfaces.
@MainActor
public struct AppSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions?

    @State private var languageAtAppear: AppLanguage?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions? = nil
    ) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
        self.hostActions = hostActions
    }

    private static let columnWidth: CGFloat = 240

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(String(localized: "settings.section.app", defaultValue: "App"))
                .accessibilityIdentifier("SettingsAppSection")
            mainCard
        }
        .task {
            if languageAtAppear == nil {
                languageAtAppear = DefaultsValueModel(store: defaultsStore, key: catalog.app.language).current
            }
        }
    }

    @ViewBuilder
    private var mainCard: some View {
        let language = DefaultsValueModel(store: defaultsStore, key: catalog.app.language)
        let appearance = DefaultsValueModel(store: defaultsStore, key: catalog.app.appearance)
        let appIcon = DefaultsValueModel(store: defaultsStore, key: catalog.app.appIcon)
        let placement = DefaultsValueModel(store: defaultsStore, key: catalog.app.newWorkspacePlacement)
        let inheritDir = DefaultsValueModel(store: defaultsStore, key: catalog.app.workspaceInheritWorkingDirectory)
        let minimalMode = DefaultsValueModel(store: defaultsStore, key: catalog.app.presentationMode)
        let keepWorkspaceOpen = DefaultsValueModel(store: defaultsStore, key: catalog.app.keepWorkspaceOpenWhenClosingLastSurface)
        let firstClick = DefaultsValueModel(store: defaultsStore, key: catalog.app.focusPaneOnFirstClick)
        let fileDrop = DefaultsValueModel(store: defaultsStore, key: catalog.app.fileDropDefaultBehavior)
        let preferredEditor = DefaultsValueModel(store: defaultsStore, key: catalog.app.preferredEditor)
        let openSupported = DefaultsValueModel(store: defaultsStore, key: catalog.app.openSupportedFilesInCmux)
        let openMarkdown = DefaultsValueModel(store: defaultsStore, key: catalog.app.openMarkdownInCmuxViewer)
        let iMessage = DefaultsValueModel(store: defaultsStore, key: catalog.app.iMessageMode)
        let reorder = DefaultsValueModel(store: defaultsStore, key: catalog.app.reorderOnNotification)
        let dockBadge = DefaultsValueModel(store: defaultsStore, key: catalog.notifications.dockBadge)
        let menuBarOnly = DefaultsValueModel(store: defaultsStore, key: catalog.app.menuBarOnly)
        let showInMenuBar = DefaultsValueModel(store: defaultsStore, key: catalog.notifications.showInMenuBar)
        let paneRing = DefaultsValueModel(store: defaultsStore, key: catalog.notifications.unreadPaneRing)
        let paneFlash = DefaultsValueModel(store: defaultsStore, key: catalog.notifications.paneFlash)
        let soundName = DefaultsValueModel(store: defaultsStore, key: catalog.notifications.sound)
        let soundCommand = DefaultsValueModel(store: defaultsStore, key: catalog.notifications.command)
        let telemetry = DefaultsValueModel(store: defaultsStore, key: catalog.app.sendAnonymousTelemetry)
        let confirmQuit = DefaultsValueModel(store: defaultsStore, key: catalog.app.confirmQuitMode)
        let warnCloseTab = DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingTab)
        let warnCloseX = DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingTabXButton)
        let hideCloseButton = DefaultsValueModel(store: defaultsStore, key: catalog.app.hideTabCloseButton)
        let renameSelects = DefaultsValueModel(store: defaultsStore, key: catalog.app.renameSelectsExistingName)
        let paletteAllSurfaces = DefaultsValueModel(store: defaultsStore, key: catalog.app.commandPaletteSearchesAllSurfaces)

        SettingsCard {
            // Language
            SettingsCardRow(
                configurationReview: .json("app.language"),
                String(localized: "settings.app.language", defaultValue: "Language"),
                subtitle: languageAtAppear != nil && language.current != languageAtAppear
                    ? String(localized: "settings.app.language.restartSubtitle", defaultValue: "Restart cmux to apply")
                    : nil,
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { language.current }, set: { language.set($0) })) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(languageDisplayName(lang)).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Appearance
            SettingsCardRow(
                configurationReview: .json("app.appearance"),
                String(localized: "settings.app.appearance", defaultValue: "Appearance"),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { appearance.current }, set: { appearance.set($0) })) {
                    Text(String(localized: "settings.app.appearance.system", defaultValue: "Follow System")).tag(AppearanceMode.system)
                    Text(String(localized: "settings.app.appearance.light", defaultValue: "Light")).tag(AppearanceMode.light)
                    Text(String(localized: "settings.app.appearance.dark", defaultValue: "Dark")).tag(AppearanceMode.dark)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // App Icon
            SettingsCardRow(
                configurationReview: .json("app.appIcon"),
                String(localized: "settings.app.appIcon", defaultValue: "App Icon")
            ) {
                AppIconGridPicker(model: appIcon)
            }
            SettingsCardDivider()

            // New Workspace Placement
            SettingsCardRow(
                configurationReview: .json("app.newWorkspacePlacement"),
                String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"),
                subtitle: workspacePlacementSubtitle(placement.current),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { placement.current }, set: { placement.set($0) })) {
                    Text(String(localized: "settings.app.newWorkspacePlacement.top", defaultValue: "Top")).tag(WorkspacePlacement.top)
                    Text(String(localized: "settings.app.newWorkspacePlacement.end", defaultValue: "End")).tag(WorkspacePlacement.end)
                    Text(String(localized: "settings.app.newWorkspacePlacement.afterCurrent", defaultValue: "After Current")).tag(WorkspacePlacement.afterCurrent)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Inherit Working Directory
            SettingsCardRow(
                configurationReview: .json("app.workspaceInheritWorkingDirectory"),
                String(localized: "settings.app.workspaceInheritWorkingDirectory", defaultValue: "Inherit Workspace Working Directory"),
                subtitle: inheritDir.current
                    ? String(localized: "settings.app.workspaceInheritWorkingDirectory.subtitleOn", defaultValue: "New workspaces start in the same working directory as the previous pane.")
                    : String(localized: "settings.app.workspaceInheritWorkingDirectory.subtitleOff", defaultValue: "New workspaces start in the default home directory.")
            ) {
                Toggle("", isOn: Binding(get: { inheritDir.current }, set: { inheritDir.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsWorkspaceInheritWorkingDirectoryToggle")
            }
            SettingsCardDivider()

            // Minimal Mode
            SettingsCardRow(
                configurationReview: .json("app.minimalMode"),
                String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode"),
                subtitle: minimalMode.current == .minimal
                    ? String(localized: "settings.app.minimalMode.subtitleOn", defaultValue: "Compact chrome with reduced controls.")
                    : String(localized: "settings.app.minimalMode.subtitleOff", defaultValue: "Standard chrome with full controls.")
            ) {
                Toggle("", isOn: Binding(
                    get: { minimalMode.current == .minimal },
                    set: { minimalMode.set($0 ? .minimal : .standard) }
                ))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMinimalModeToggle")
            }
            SettingsCardDivider()

            // Keep Workspace Open
            SettingsCardRow(
                configurationReview: .json("app.keepWorkspaceOpenWhenClosingLastSurface"),
                String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut", defaultValue: "Keep Workspace Open When Closing Last Surface"),
                subtitle: keepWorkspaceOpen.current
                    ? String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut.subtitleOn", defaultValue: "Workspaces stay in the sidebar even after the last pane closes.")
                    : String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut.subtitleOff", defaultValue: "Closing the last pane removes the workspace.")
            ) {
                Toggle("", isOn: Binding(get: { keepWorkspaceOpen.current }, set: { keepWorkspaceOpen.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Focus Pane on First Click
            SettingsCardRow(
                configurationReview: .json("app.focusPaneOnFirstClick"),
                String(localized: "settings.app.paneFirstClickFocus", defaultValue: "Focus Pane on First Click"),
                subtitle: firstClick.current
                    ? String(localized: "settings.app.paneFirstClickFocus.subtitleOn", defaultValue: "Clicking a pane focuses it on the first click.")
                    : String(localized: "settings.app.paneFirstClickFocus.subtitleOff", defaultValue: "Clicking a pane brings the window forward; a second click focuses the pane.")
            ) {
                Toggle("", isOn: Binding(get: { firstClick.current }, set: { firstClick.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // File Drops
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.app.fileDrop.defaultBehavior", defaultValue: "File Drops"),
                subtitle: fileDropSubtitle(fileDrop.current),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { fileDrop.current }, set: { fileDrop.set($0) })) {
                    Text(String(localized: "settings.app.fileDrop.text", defaultValue: "Insert File Path")).tag(FileDropDefaultBehavior.text)
                    Text(String(localized: "settings.app.fileDrop.preview", defaultValue: "Open in cmux Preview")).tag(FileDropDefaultBehavior.preview)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Preferred Editor
            SettingsCardRow(
                configurationReview: .json("app.preferredEditor"),
                String(localized: "settings.app.preferredEditor", defaultValue: "Open Files With"),
                subtitle: String(localized: "settings.app.preferredEditor.subtitle", defaultValue: "Command used when Cmd-click file previews are disabled or a file is unsupported. Leave empty for system default.")
            ) {
                TextField(
                    String(localized: "settings.app.preferredEditor.placeholder", defaultValue: "e.g. code, zed, subl"),
                    text: Binding(get: { preferredEditor.current }, set: { preferredEditor.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
            SettingsCardDivider()

            // Open Supported Files in cmux
            SettingsCardRow(
                configurationReview: .json("app.openSupportedFilesInCmux"),
                String(localized: "settings.app.openSupportedFilesInCmux", defaultValue: "Open Supported Files in cmux"),
                subtitle: String(localized: "settings.app.openSupportedFilesInCmux.subtitle", defaultValue: "Cmd-clicking readable files opens text, code, PDFs, images, audio, video, and Quick Look previews in cmux.")
            ) {
                Toggle("", isOn: Binding(get: { openSupported.current }, set: { openSupported.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Terminal Config (host action)
            if let hostActions {
                SettingsCardRow(
                    configurationReview: .action,
                    String(localized: "settings.app.configWindow", defaultValue: "Terminal Config"),
                    subtitle: String(localized: "settings.app.configWindow.subtitle", defaultValue: "Open the cmux terminal config and generated preview in one utility window."),
                    controlWidth: Self.columnWidth
                ) {
                    Button(String(localized: "settings.app.configWindow.openButton", defaultValue: "Open Config")) {
                        hostActions.openTerminalConfigWindow()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                SettingsCardDivider()
            }

            // Open Markdown in cmux Viewer
            SettingsCardRow(
                configurationReview: .json("app.openMarkdownInCmuxViewer"),
                String(localized: "settings.app.openMarkdownInCmuxViewer", defaultValue: "Open Markdown in cmux Viewer"),
                subtitle: String(localized: "settings.app.openMarkdownInCmuxViewer.subtitle", defaultValue: "When supported file routing is on, Cmd-clicking Markdown files opens the rendered cmux markdown viewer instead of the generic file preview.")
            ) {
                Toggle("", isOn: Binding(get: { openMarkdown.current }, set: { openMarkdown.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // iMessage Mode
            SettingsCardRow(
                configurationReview: .json("app.iMessageMode"),
                String(localized: "settings.app.iMessageMode", defaultValue: "iMessage Mode"),
                subtitle: String(localized: "settings.app.iMessageMode.subtitle", defaultValue: "Move a workspace to the top and show the submitted message when you send an agent prompt.")
            ) {
                Toggle("", isOn: Binding(get: { iMessage.current }, set: { iMessage.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Reorder on Notification
            SettingsCardRow(
                configurationReview: .json("app.reorderOnNotification"),
                String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"),
                subtitle: String(localized: "settings.app.reorderOnNotification.subtitle", defaultValue: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions.")
            ) {
                Toggle("", isOn: Binding(get: { reorder.current }, set: { reorder.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Dock Badge
            SettingsCardRow(
                configurationReview: .json("notifications.dockBadge"),
                String(localized: "settings.app.dockBadge", defaultValue: "Dock Badge"),
                subtitle: String(localized: "settings.app.dockBadge.subtitle", defaultValue: "Show unread count on app icon (Dock and Cmd+Tab).")
            ) {
                Toggle("", isOn: Binding(get: { dockBadge.current }, set: { dockBadge.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Menu Bar Only
            SettingsCardRow(
                configurationReview: .json("app.menuBarOnly"),
                String(localized: "settings.app.menuBarOnly", defaultValue: "Menu Bar Only"),
                subtitle: String(localized: "settings.app.menuBarOnly.subtitle", defaultValue: "Hide the Dock icon and Cmd+Tab entry. Use the menu bar item to show cmux.")
            ) {
                Toggle("", isOn: Binding(get: { menuBarOnly.current }, set: { menuBarOnly.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsMenuBarOnlyToggle")
            }
            SettingsCardDivider()

            // Show in Menu Bar
            SettingsCardRow(
                configurationReview: .json("notifications.showInMenuBar"),
                String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar"),
                subtitle: String(localized: "settings.app.showInMenuBar.subtitle", defaultValue: "Keep cmux in the menu bar for unread notifications and quick actions.")
            ) {
                Toggle("", isOn: Binding(get: { showInMenuBar.current }, set: { showInMenuBar.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .disabled(menuBarOnly.current)
            SettingsCardDivider()

            // Unread Pane Ring
            SettingsCardRow(
                configurationReview: .json("notifications.unreadPaneRing"),
                String(localized: "settings.notifications.paneRing.title", defaultValue: "Unread Pane Ring"),
                subtitle: String(localized: "settings.notifications.paneRing.subtitle", defaultValue: "Show a blue ring around panes with unread notifications.")
            ) {
                Toggle("", isOn: Binding(get: { paneRing.current }, set: { paneRing.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Pane Flash
            SettingsCardRow(
                configurationReview: .json("notifications.paneFlash"),
                String(localized: "settings.notifications.paneFlash.title", defaultValue: "Pane Flash"),
                subtitle: String(localized: "settings.notifications.paneFlash.subtitle", defaultValue: "Briefly flash a blue outline when cmux highlights a pane.")
            ) {
                Toggle("", isOn: Binding(get: { paneFlash.current }, set: { paneFlash.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }

            if let hostActions {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .action,
                    String(localized: "settings.notifications.desktop", defaultValue: "Desktop Notifications"),
                    subtitle: String(localized: "settings.notifications.desktop.subtitle", defaultValue: "Request permission, open System Settings, or send a test notification.")
                ) {
                    HStack(spacing: 6) {
                        Button(String(localized: "settings.notifications.desktop.request", defaultValue: "Request")) {
                            hostActions.requestNotificationAuthorization()
                        }
                        .controlSize(.small)
                        Button(String(localized: "settings.notifications.desktop.system", defaultValue: "System Settings…")) {
                            hostActions.openSystemNotificationSettings()
                        }
                        .controlSize(.small)
                        Button(String(localized: "settings.notifications.desktop.sendTest", defaultValue: "Send Test")) {
                            hostActions.sendTestNotification()
                        }
                        .controlSize(.small)
                    }
                }
            }
            SettingsCardDivider()

            // Notification Sound — Picker over NSSound names with
            // Preview button. Custom-file path field appears when the
            // user selects "custom".
            notificationSoundRow(model: soundName)
            SettingsCardDivider()

            // Notification Command
            SettingsCardRow(
                configurationReview: .json("notifications.command"),
                String(localized: "settings.notifications.command", defaultValue: "Notification Command"),
                subtitle: String(localized: "settings.notifications.command.subtitle", defaultValue: "Run a shell command when a notification arrives. $CMUX_NOTIFICATION_TITLE, $CMUX_NOTIFICATION_SUBTITLE, $CMUX_NOTIFICATION_BODY are set.")
            ) {
                TextField(
                    String(localized: "settings.notifications.command.placeholder", defaultValue: "say \"done\""),
                    text: Binding(get: { soundCommand.current }, set: { soundCommand.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
            SettingsCardDivider()

            // Telemetry
            SettingsCardRow(
                configurationReview: .json("app.sendAnonymousTelemetry"),
                String(localized: "settings.app.telemetry", defaultValue: "Send anonymous telemetry"),
                subtitle: String(localized: "settings.app.telemetry.subtitle", defaultValue: "Share anonymized crash and usage data to help improve cmux.")
            ) {
                Toggle("", isOn: Binding(get: { telemetry.current }, set: { telemetry.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Warn Before Quit
            SettingsCardRow(
                configurationReview: .json("app.confirmQuit", "app.warnBeforeQuit"),
                String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"),
                subtitle: confirmQuitSubtitle(confirmQuit.current),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { confirmQuit.current }, set: { confirmQuit.set($0) })) {
                    Text(String(localized: "settings.app.warnBeforeQuit.always", defaultValue: "Always")).tag(ConfirmQuitMode.always)
                    Text(String(localized: "settings.app.warnBeforeQuit.dirtyOnly", defaultValue: "Dirty Only")).tag(ConfirmQuitMode.dirtyOnly)
                    Text(String(localized: "settings.app.warnBeforeQuit.never", defaultValue: "Never")).tag(ConfirmQuitMode.never)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            SettingsCardDivider()

            // Warn Before Closing Tab
            SettingsCardRow(
                configurationReview: .json("app.warnBeforeClosingTab"),
                String(localized: "settings.app.warnBeforeClosingTab", defaultValue: "Warn Before Closing Tab"),
                subtitle: warnCloseTab.current
                    ? String(localized: "settings.app.warnBeforeClosingTab.subtitleOn", defaultValue: "Show a confirmation before closing a tab.")
                    : String(localized: "settings.app.warnBeforeClosingTab.subtitleOff", defaultValue: "Tabs close immediately without confirmation.")
            ) {
                Toggle("", isOn: Binding(get: { warnCloseTab.current }, set: { warnCloseTab.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Warn Before Tab Close Button
            SettingsCardRow(
                configurationReview: .json("app.warnBeforeClosingTabXButton"),
                String(localized: "settings.app.warnBeforeClosingTabXButton", defaultValue: "Warn Before Tab Close Button"),
                subtitle: warnCloseX.current
                    ? String(localized: "settings.app.warnBeforeClosingTabXButton.subtitleOn", defaultValue: "Clicks on tab X buttons show a confirmation.")
                    : String(localized: "settings.app.warnBeforeClosingTabXButton.subtitleOff", defaultValue: "Tab X buttons close tabs immediately.")
            ) {
                Toggle("", isOn: Binding(get: { warnCloseX.current }, set: { warnCloseX.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(hideCloseButton.current)
            }
            SettingsCardDivider()

            // Hide Tab Close Button
            SettingsCardRow(
                configurationReview: .json("app.hideTabCloseButton"),
                String(localized: "settings.app.hideTabCloseButton", defaultValue: "Hide Tab Close Button"),
                subtitle: hideCloseButton.current
                    ? String(localized: "settings.app.hideTabCloseButton.subtitleOn", defaultValue: "Tab close buttons are hidden.")
                    : String(localized: "settings.app.hideTabCloseButton.subtitleOff", defaultValue: "Tab close buttons appear on hover and on the active tab.")
            ) {
                Toggle("", isOn: Binding(get: { hideCloseButton.current }, set: { hideCloseButton.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Rename Selects Existing Name
            SettingsCardRow(
                configurationReview: .json("app.renameSelectsExistingName"),
                String(localized: "settings.app.renameSelectsName", defaultValue: "Rename Selects Existing Name"),
                subtitle: renameSelects.current
                    ? String(localized: "settings.app.renameSelectsName.subtitleOn", defaultValue: "Command Palette rename starts with all text selected.")
                    : String(localized: "settings.app.renameSelectsName.subtitleOff", defaultValue: "Command Palette rename keeps the caret at the end.")
            ) {
                Toggle("", isOn: Binding(get: { renameSelects.current }, set: { renameSelects.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Command Palette Searches All Surfaces
            SettingsCardRow(
                configurationReview: .json("app.commandPaletteSearchesAllSurfaces"),
                String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces"),
                subtitle: paletteAllSurfaces.current
                    ? String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOn", defaultValue: "Cmd+P also matches panel surfaces across workspaces.")
                    : String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOff", defaultValue: "Cmd+P matches workspace rows only.")
            ) {
                Toggle("", isOn: Binding(get: { paletteAllSurfaces.current }, set: { paletteAllSurfaces.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("CommandPaletteSearchAllSurfacesToggle")
            }
        }
    }

    /// Standard macOS notification sound names plus cmux-specific
    /// sentinels for default / none / custom-file. Matches the
    /// legacy `NotificationSoundSettings.systemSounds` list shape.
    private static let systemSoundOptions: [(value: String, label: String)] = [
        ("default", "System Default"),
        ("none", "None"),
        ("Basso", "Basso"),
        ("Blow", "Blow"),
        ("Bottle", "Bottle"),
        ("Frog", "Frog"),
        ("Funk", "Funk"),
        ("Glass", "Glass"),
        ("Hero", "Hero"),
        ("Morse", "Morse"),
        ("Ping", "Ping"),
        ("Pop", "Pop"),
        ("Purr", "Purr"),
        ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"),
        ("Tink", "Tink"),
        ("custom", "Custom File…"),
    ]

    @ViewBuilder
    private func notificationSoundRow(model: DefaultsValueModel<String>) -> some View {
        let customFile = DefaultsValueModel(store: defaultsStore, key: catalog.notifications.customSoundFilePath)
        SettingsCardRow(
            configurationReview: .json("notifications.sound", "notifications.customSoundFilePath"),
            String(localized: "settings.notifications.sound.title", defaultValue: "Notification Sound"),
            subtitle: String(localized: "settings.notifications.sound.subtitle", defaultValue: "Sound played when a notification arrives.")
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { model.current }, set: { model.set($0) })) {
                        ForEach(Self.systemSoundOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Button {
                        hostActions?.previewNotificationSound()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.current == "none" || hostActions == nil)
                }
                if model.current == "custom" {
                    HStack(spacing: 6) {
                        TextField(
                            String(localized: "settings.notifications.sound.custom.placeholder", defaultValue: "/path/to/sound.aiff"),
                            text: Binding(get: { customFile.current }, set: { customFile.set($0) })
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        Button(String(localized: "settings.notifications.sound.custom.clear.button", defaultValue: "Clear")) {
                            customFile.reset()
                        }
                        .controlSize(.small)
                        .disabled(customFile.current.isEmpty)
                    }
                }
            }
        }
    }

    private func languageDisplayName(_ language: AppLanguage) -> String {
        switch language {
        case .system: return String(localized: "settings.app.language.system", defaultValue: "Follow System")
        case .en: return "English"
        case .ar: return "العربية"
        case .bs: return "Bosanski"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .da: return "Dansk"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .nb: return "Norsk Bokmål"
        case .pl: return "Polski"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский"
        case .th: return "ไทย"
        case .tr: return "Türkçe"
        case .vi: return "Tiếng Việt"
        }
    }

    private func workspacePlacementSubtitle(_ placement: WorkspacePlacement) -> String {
        switch placement {
        case .top: return String(localized: "settings.app.newWorkspacePlacement.top.subtitle", defaultValue: "New workspaces appear at the top of the sidebar.")
        case .end: return String(localized: "settings.app.newWorkspacePlacement.end.subtitle", defaultValue: "New workspaces appear at the end of the sidebar.")
        case .afterCurrent: return String(localized: "settings.app.newWorkspacePlacement.afterCurrent.subtitle", defaultValue: "New workspaces appear right after the current one.")
        }
    }

    private func fileDropSubtitle(_ behavior: FileDropDefaultBehavior) -> String {
        switch behavior {
        case .text: return String(localized: "settings.app.fileDrop.text.subtitle", defaultValue: "Dropping a file inserts its path as terminal text.")
        case .preview: return String(localized: "settings.app.fileDrop.preview.subtitle", defaultValue: "Dropping a file opens it in a cmux preview surface.")
        }
    }

    private func confirmQuitSubtitle(_ mode: ConfirmQuitMode) -> String {
        switch mode {
        case .always: return String(localized: "settings.app.warnBeforeQuit.always.subtitle", defaultValue: "Always show a confirmation when ⌘Q is pressed.")
        case .dirtyOnly: return String(localized: "settings.app.warnBeforeQuit.dirtyOnly.subtitle", defaultValue: "Confirm only when there are active workspaces.")
        case .never: return String(localized: "settings.app.warnBeforeQuit.never.subtitle", defaultValue: "Quit immediately on ⌘Q.")
        }
    }
}
