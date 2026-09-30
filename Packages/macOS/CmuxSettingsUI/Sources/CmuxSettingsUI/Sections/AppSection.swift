import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **App** section — mirrors the legacy in-app section row-for-row
/// inside a single `SettingsCard`: Language, Appearance, App Icon,
/// New Workspace Placement, Inherit Working Directory, Minimal Mode,
/// Keep Workspace Open When Closing Last Surface, Focus Pane on
/// First Click, File Drops, Open Files With, Open Supported Files in
/// cmux, Terminal Config link, Open Markdown in cmux Viewer,
/// Markdown Viewer typography, iMessage Mode, Reorder on Notification, Dock Badge, Menu Bar
/// Only, Show in Menu Bar, Unread Pane Ring, Pane Flash, Desktop
/// Notifications, Notification Sound, Notification Command, Send
/// anonymous telemetry, Warn Before Quit, Warn Before Closing Tab /
/// X Button / Hide Tab Close Button, Rename Selects Existing Name,
/// Command Palette Searches All Surfaces.
@MainActor
public struct AppSection: View {
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions

    // Every bound value-model lives here as view state, constructed once
    // and persisted across renders so the @Observable change tracking
    // actually drives invalidation.
    @State private var language: DefaultsValueModel<AppLanguage>
    @State private var appearance: DefaultsValueModel<AppearanceMode>
    @State private var accentColor: DefaultsValueModel<CmuxAccentColorMode>
    @State private var appIcon: DefaultsValueModel<AppIconMode>
    @State private var placement: DefaultsValueModel<WorkspacePlacement>
    @State private var inheritDir: DefaultsValueModel<Bool>
    @State private var minimalMode: DefaultsValueModel<WorkspacePresentationMode>
    @State private var keepWorkspaceOpen: DefaultsValueModel<Bool>
    @State private var firstClick: DefaultsValueModel<Bool>
    @State private var focusHistoryIncludesPanesAndTabs: DefaultsValueModel<Bool>
    @State private var equalizeSplitsOnCreate: DefaultsValueModel<Bool>
    @State private var fileDrop: DefaultsValueModel<FileDropDefaultBehavior>
    @State private var preferredEditor: DefaultsValueModel<String>
    @State private var openSupported: DefaultsValueModel<Bool>
    @State private var openMarkdown: DefaultsValueModel<Bool>
    @State private var globalFontMagnification: DefaultsValueModel<Int>
    @State private var markdownFontSize: DefaultsValueModel<Int>
    @State private var markdownFontFamily: DefaultsValueModel<String>
    @State private var markdownMaxWidth: DefaultsValueModel<Int>
    @State private var canvasPaneGap: DefaultsValueModel<Int>
    @State private var canvasSnapping: DefaultsValueModel<Bool>
    @State private var fileEditorWordWrap: DefaultsValueModel<Bool>
    @State private var fileEditorSyntaxHighlighting: DefaultsValueModel<Bool>
    @State private var fileEditorLineNumbers: DefaultsValueModel<Bool>
    @State private var fileEditorIndentGuides: DefaultsValueModel<Bool>
    @State private var fileEditorCurrentLineHighlight: DefaultsValueModel<Bool>
    @State private var fileEditorTabWidth: DefaultsValueModel<Int>
    @State private var iMessage: DefaultsValueModel<Bool>
    @State private var reorder: DefaultsValueModel<WorkspaceAutoReorderMode>
    @State private var dockBadge: DefaultsValueModel<Bool>
    @State private var menuBarOnly: DefaultsValueModel<Bool>
    @State private var showInMenuBar: DefaultsValueModel<Bool>
    @State private var paneRing: DefaultsValueModel<Bool>
    @State private var paneFlash: DefaultsValueModel<Bool>
    @State private var paneFlashDoubleBlink: DefaultsValueModel<Bool>
    @State private var paneFlashThemeColor: DefaultsValueModel<Bool>
    @State private var desktopNotifications: DesktopNotificationAuthorizationModel
    @State private var agentPermissionPrompt: DefaultsValueModel<Bool>
    @State private var agentTurnComplete: DefaultsValueModel<String>
    @State private var agentIdleReminder: DefaultsValueModel<Bool>
    @State private var soundName: DefaultsValueModel<String>
    @State private var soundWhenFocused: DefaultsValueModel<Bool>
    @State private var soundCommand: DefaultsValueModel<String>
    @State private var customSoundFile: DefaultsValueModel<String>
    @State private var soundOverrides: DefaultsValueModel<String>
    @State private var soundOverridesModel: NotificationSoundOverridesModel
    private let soundAgentCache: NotificationSoundAgentCache
    @State private var telemetry: DefaultsValueModel<Bool>
    @State private var confirmQuit: DefaultsValueModel<ConfirmQuitMode>
    @State private var warnCloseTab: DefaultsValueModel<Bool>
    @State private var warnCloseX: DefaultsValueModel<Bool>
    @State private var warnCloseWorkspace: DefaultsValueModel<Bool>
    @State private var warnCloseWindow: DefaultsValueModel<Bool>
    @State private var hideCloseButton: DefaultsValueModel<Bool>
    @State private var renameSelects: DefaultsValueModel<Bool>
    @State private var paletteAllSurfaces: DefaultsValueModel<Bool>

    @State private var languageAtAppear: AppLanguage?
    // Sticky: a picker change can rewrite the OS AppleLanguages override even when the selection returns to its starting value (clearing a preserved foreign override via an explicit pick, then System), so the restart hint must not rely on the value comparison alone.
    @State private var languageOverrideTouched = false
    @State private var telemetryAtAppear: Bool?
    /// `DisableTelemetry` (MDM): the opt-in is moot while a profile forces
    /// telemetry off, so the row says so and locks; re-read on change signals.
    @State private var telemetryManagedByPolicy = ManagedDevicePolicy().isEnforced(.disableTelemetry)

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions,
        soundAgentCache: NotificationSoundAgentCache = NotificationSoundAgentCache()
    ) {
        self.catalog = catalog
        self.hostActions = hostActions
        self.soundAgentCache = soundAgentCache
        _language = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.language))
        _appearance = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.appearance))
        _accentColor = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.accentColor))
        _appIcon = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.appIcon))
        _placement = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.newWorkspacePlacement))
        _inheritDir = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.workspaceInheritWorkingDirectory))
        _minimalMode = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.presentationMode))
        _keepWorkspaceOpen = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.keepWorkspaceOpenWhenClosingLastSurface))
        _firstClick = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.focusPaneOnFirstClick))
        _focusHistoryIncludesPanesAndTabs = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.focusHistoryIncludesPanesAndTabs))
        _equalizeSplitsOnCreate = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.equalizeSplitsOnCreate))
        _fileDrop = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.fileDropDefaultBehavior))
        _preferredEditor = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.preferredEditor))
        _openSupported = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.openSupportedFilesInCmux))
        _openMarkdown = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.openMarkdownInCmuxViewer))
        _globalFontMagnification = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.globalFontMagnification))
        _markdownFontSize = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.fontSize))
        _markdownFontFamily = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.fontFamily))
        _markdownMaxWidth = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.markdown.maxWidth))
        _canvasPaneGap = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.canvas.paneGap))
        _canvasSnapping = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.canvas.snappingEnabled))
        _fileEditorWordWrap = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.wordWrap))
        _fileEditorSyntaxHighlighting = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.syntaxHighlighting))
        _fileEditorLineNumbers = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.lineNumbers))
        _fileEditorIndentGuides = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.indentGuides))
        _fileEditorCurrentLineHighlight = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.currentLineHighlight))
        _fileEditorTabWidth = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.tabWidth))
        _iMessage = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.iMessageMode))
        _reorder = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.reorderOnNotification))
        _dockBadge = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.dockBadge))
        _menuBarOnly = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.menuBarOnly))
        _showInMenuBar = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.showInMenuBar))
        _paneRing = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.unreadPaneRing))
        _paneFlash = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.paneFlash))
        _paneFlashDoubleBlink = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.paneFlashDoubleBlink))
        _paneFlashThemeColor = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.paneFlashThemeColor))
        _desktopNotifications = State(initialValue: DesktopNotificationAuthorizationModel(hostActions: hostActions))
        _agentPermissionPrompt = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.agentPermissionPrompt))
        _agentTurnComplete = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.agentTurnComplete))
        _agentIdleReminder = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.agentIdleReminder))
        _soundName = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.sound))
        _soundWhenFocused = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.soundWhenFocused))
        _soundCommand = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.command))
        _customSoundFile = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.customSoundFilePath))
        _soundOverrides = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.notifications.soundOverrides))
        _soundOverridesModel = State(initialValue: NotificationSoundOverridesModel(
            initialJSON: defaultsStore.initialValue(for: catalog.notifications.soundOverrides)
        ))
        _telemetry = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.sendAnonymousTelemetry))
        _confirmQuit = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.confirmQuitMode))
        _warnCloseTab = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingTab))
        _warnCloseX = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingTabXButton))
        _warnCloseWorkspace = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingWorkspace))
        _warnCloseWindow = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeClosingWindow))
        _hideCloseButton = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.hideTabCloseButton))
        _renameSelects = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.renameSelectsExistingName))
        _paletteAllSurfaces = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.commandPaletteSearchesAllSurfaces))
    }

    private static let columnWidth: CGFloat = 196

    /// Languages legacy `AppLanguage` exposes (cmuxApp.swift line
    /// 4338). The shared `CmuxSettings.AppLanguage` adds `.vi` for a
    /// future Vietnamese localization that the legacy in-app picker
    /// doesn't surface yet; filter it out here so the Settings UI
    /// matches the legacy menu shape exactly.
    private static let legacyLanguageCases: [AppLanguage] = [
        .system, .en, .ar, .bs, .zhHans, .zhHant, .da, .de, .es, .fr,
        .it, .ja, .ko, .nb, .pl, .ptBR, .ru, .th, .tr,
    ]

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.app", defaultValue: "App"), section: .app)
                .accessibilityIdentifier("SettingsAppSection")
            mainCard
            AppChannelSwitchCard(hostActions: hostActions)
        }
        .task {
            startSettingsObservation([language, appearance, accentColor, appIcon, placement, inheritDir, minimalMode, keepWorkspaceOpen, firstClick, focusHistoryIncludesPanesAndTabs, equalizeSplitsOnCreate, fileDrop, preferredEditor, openSupported, openMarkdown, globalFontMagnification, markdownFontSize, markdownFontFamily, markdownMaxWidth, canvasPaneGap, canvasSnapping, fileEditorWordWrap, fileEditorSyntaxHighlighting, fileEditorLineNumbers, fileEditorIndentGuides, fileEditorCurrentLineHighlight, fileEditorTabWidth, iMessage, reorder, dockBadge, menuBarOnly, showInMenuBar, paneRing, paneFlash, paneFlashDoubleBlink, paneFlashThemeColor, desktopNotifications, agentPermissionPrompt, agentTurnComplete, agentIdleReminder, soundName, soundWhenFocused, soundCommand, customSoundFile, soundOverrides, telemetry, confirmQuit, warnCloseTab, warnCloseX, warnCloseWorkspace, warnCloseWindow, hideCloseButton, renameSelects, paletteAllSurfaces])
            await soundAgentCache.loadIfNeeded { await hostActions.notificationSoundAgentOptions() }
            if languageAtAppear == nil { languageAtAppear = language.current }; if telemetryAtAppear == nil { telemetryAtAppear = telemetry.current }
        }
        .task {
            for await _ in ManagedDevicePolicy.changeSignals() {
                telemetryManagedByPolicy = ManagedDevicePolicy().isEnforced(.disableTelemetry)
            }
        }
        .onChange(of: soundOverrides.current) { _, newValue in
            soundOverridesModel.accept(newValue)
        }
    }

    private var globalFontMagnificationSubtitle: String {
        String(
            localized: "settings.app.globalFontMagnification.subtitle",
            defaultValue: "Scales all text in cmux. Command-Plus and Command-Minus still zoom the focused pane."
        )
    }

    private func setGlobalFontMagnification(_ percent: Int) {
        let clamped = GlobalFontMagnification.clamp(percent)
        globalFontMagnification.set(clamped) { NotificationCenter.default.post(name: GlobalFontMagnification.didChangeNotification, object: nil) }
    }

    @ViewBuilder
    private var mainCard: some View {
        SettingsCard {
            // Language
            SettingsCardRow(
                configurationReview: .json("app.language"),
                String(localized: "settings.app.language", defaultValue: "Language"),
                subtitle: languageOverrideTouched || (languageAtAppear != nil && language.current != languageAtAppear) ? String(localized: "settings.app.language.restartSubtitle", defaultValue: "Restart cmux to apply") : nil,
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { language.current }, set: { newLanguage in if newLanguage != language.current { languageOverrideTouched = true }; language.set(newLanguage) { hostActions.applyLanguageOverride(newLanguage) } })) {
                    ForEach(Self.legacyLanguageCases, id: \.self) { lang in
                        Text(languageDisplayName(lang)).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Theme — three-up visual picker mirroring legacy
            ThemePickerRow(
                selectedMode: appearance.current,
                onSelect: { appearance.set($0) }
            )
            .settingsSearchAnchors(["setting:app:appearance"])
            SettingsCardDivider()

            // Accent Color
            SettingsCardRow(
                configurationReview: .json("app.accentColor"),
                String(localized: "settings.app.accentColor", defaultValue: "Accent Color"),
                subtitle: String(localized: "settings.app.accentColor.subtitle", defaultValue: "Color of the selected workspace, attention ring, agent status, and other cmux highlights. System follows the macOS accent color."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { accentColor.current }, set: { accentColor.set($0) })) {
                    Text(String(localized: "settings.app.accentColor.cmux", defaultValue: "cmux Blue")).tag(CmuxAccentColorMode.cmux)
                    Text(String(localized: "settings.app.accentColor.system", defaultValue: "System")).tag(CmuxAccentColorMode.system)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("SettingsAccentColorPicker")
            }
            SettingsCardDivider()

            // App Icon — three-up visual picker mirroring legacy
            AppIconPickerRow(
                selectedMode: appIcon.current,
                onSelect: { appIcon.set($0) }
            )
            .settingsSearchAnchors(["setting:app:app-icon"])
            SettingsCardDivider()

            // New Workspace Placement
            SettingsCardRow(
                configurationReview: .json("app.newWorkspacePlacement"),
                String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"),
                subtitle: String(localized: "settings.app.newWorkspacePlacement.subtitle", defaultValue: "Choose where new workspaces appear in the sidebar."),
                controlWidth: Self.columnWidth
            ) {
                // Order matches legacy NewWorkspacePlacement.allCases:
                // top, afterCurrent, end.
                Picker("", selection: Binding(get: { placement.current }, set: { placement.set($0) })) {
                    Text(String(localized: "workspace.placement.top", defaultValue: "Top")).tag(WorkspacePlacement.top)
                    Text(String(localized: "workspace.placement.afterCurrent", defaultValue: "After current")).tag(WorkspacePlacement.afterCurrent)
                    Text(String(localized: "workspace.placement.end", defaultValue: "End")).tag(WorkspacePlacement.end)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Workspace Layouts
            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:app:workspace-layouts",
                String(localized: "settings.app.workspaceLayouts", defaultValue: "Workspace Layouts"),
                subtitle: String(localized: "settings.app.workspaceLayouts.subtitle", defaultValue: "Edit the saved layouts offered in the new-workspace menu."),
                controlWidth: Self.columnWidth
            ) {
                Button(String(localized: "settings.app.workspaceLayouts.customize", defaultValue: "Customize…")) {
                    hostActions.customizeWorkspaceLayouts()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            SettingsCardDivider()

            // Inherit Working Directory
            SettingsCardRow(
                configurationReview: .json("app.workspaceInheritWorkingDirectory"),
                String(localized: "settings.app.workspaceInheritWorkingDirectory", defaultValue: "Inherit Workspace Working Directory"),
                subtitle: String(localized: "settings.app.workspaceInheritWorkingDirectory.subtitle", defaultValue: "Starts new workspaces in the working directory of the current workspace.")
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
                subtitle: String(localized: "settings.app.minimalMode.subtitle", defaultValue: "Hides the workspace title bar and shows its controls in the sidebar.")
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

            // Keep Workspace Open. The stored value carries close-on-last-
            // surface semantics (true = close), so the "Keep Open" toggle
            // and its subtitle bind to the inverse, matching legacy.
            SettingsCardRow(
                configurationReview: .json("app.keepWorkspaceOpenWhenClosingLastSurface"),
                String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut", defaultValue: "Keep Workspace Open When Closing Last Surface"),
                subtitle: String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut.subtitle", defaultValue: "Closing the last surface in a workspace keeps the workspace open.")
            ) {
                Toggle("", isOn: Binding(get: { !keepWorkspaceOpen.current }, set: { keepWorkspaceOpen.set(!$0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Focus Pane on First Click
            SettingsCardRow(
                configurationReview: .json("app.focusPaneOnFirstClick"),
                String(localized: "settings.app.paneFirstClickFocus", defaultValue: "Focus Pane on First Click"),
                subtitle: String(localized: "settings.app.paneFirstClickFocus.subtitle", defaultValue: "Clicking a pane while cmux is in the background focuses that pane right away.")
            ) {
                Toggle("", isOn: Binding(get: { firstClick.current }, set: { firstClick.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Focus History Scope
            SettingsCardRow(
                configurationReview: .json("app.focusHistoryIncludesPanesAndTabs"),
                String(localized: "settings.app.focusHistoryIncludesPanesAndTabs", defaultValue: "Include Panes and Tabs in Focus History"),
                subtitle: String(localized: "settings.app.focusHistoryIncludesPanesAndTabs.subtitle", defaultValue: "Using Back and Forward also returns to previous panes and tabs.")
            ) {
                Toggle("", isOn: Binding(
                    get: { focusHistoryIncludesPanesAndTabs.current },
                    set: { focusHistoryIncludesPanesAndTabs.set($0) }
                ))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsFocusHistoryIncludesPanesAndTabsToggle")
            }
            SettingsCardDivider()

            // Equalize Splits on Create
            SettingsCardRow(
                configurationReview: .json("app.equalizeSplitsOnCreate"),
                String(localized: "settings.app.equalizeSplitsOnCreate", defaultValue: "Equalize Splits on Create"),
                subtitle: String(localized: "settings.app.equalizeSplitsOnCreate.subtitle", defaultValue: "Splitting a pane makes the panes in that direction equal in size.")
            ) {
                Toggle("", isOn: Binding(
                    get: { equalizeSplitsOnCreate.current },
                    set: { equalizeSplitsOnCreate.set($0) }
                ))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsEqualizeSplitsOnCreateToggle")
            }
            SettingsCardDivider()

            // File Drops
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:app:file-drops",
                String(localized: "settings.app.fileDrop.defaultBehavior", defaultValue: "File Drops"),
                subtitle: String(localized: "settings.app.fileDrop.defaultBehavior.subtitle", defaultValue: "Choose what dropping files on a terminal or editor does. Holding Shift while dragging does the other."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { fileDrop.current }, set: { fileDrop.set($0) })) {
                    Text(String(localized: "settings.app.fileDrop.defaultBehavior.text", defaultValue: "Drop path text")).tag(FileDropDefaultBehavior.text)
                    Text(String(localized: "settings.app.fileDrop.defaultBehavior.preview", defaultValue: "Open file preview")).tag(FileDropDefaultBehavior.preview)
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
            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:app:terminal-config",
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

            // Global Font Magnification
            SettingsCardRow(
                configurationReview: .json("app.globalFontMagnification"),
                String(localized: "settings.app.globalFontMagnification", defaultValue: "Global Font Magnification"),
                subtitle: globalFontMagnificationSubtitle
            ) {
                GlobalFontMagnificationControl(
                    percent: globalFontMagnification.current,
                    onChange: setGlobalFontMagnification
                )
            }
            SettingsCardDivider()

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

            // Markdown Viewer Font Size
            SettingsCardRow(
                configurationReview: .json("markdown.fontSize"),
                String(localized: "settings.app.markdownFontSize", defaultValue: "Markdown Viewer Font Size"),
                subtitle: String(localized: "settings.app.markdownFontSize.subtitle", defaultValue: "Default body font size, in points, for newly opened markdown viewers. Zoom a viewer live with Cmd-+ / Cmd-- / Cmd-0."),
                controlWidth: Self.columnWidth
            ) {
                Stepper(
                    value: Binding(get: { markdownFontSize.current }, set: { markdownFontSize.set($0) }),
                    in: 8...96
                ) {
                    Text(verbatim: "\(markdownFontSize.current)")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMarkdownFontSizeStepper")
                .accessibilityLabel(
                    String(localized: "settings.app.markdownFontSize", defaultValue: "Markdown Viewer Font Size")
                )
            }
            SettingsCardDivider()

            // Markdown Viewer Max Width
            SettingsCardRow(
                configurationReview: .json("markdown.maxWidth"),
                String(localized: "settings.app.markdownMaxWidth", defaultValue: "Markdown Viewer Max Width"),
                subtitle: String(localized: "settings.app.markdownMaxWidth.subtitle", defaultValue: "Default maximum reading column width, in CSS pixels, for newly opened markdown viewers."),
                controlWidth: Self.columnWidth
            ) {
                Stepper(
                    value: Binding(get: { markdownMaxWidth.current }, set: { markdownMaxWidth.set($0) }),
                    in: 320...2400,
                    step: 20
                ) {
                    Text(verbatim: "\(markdownMaxWidth.current)")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsMarkdownMaxWidthStepper")
                .accessibilityLabel(
                    String(localized: "settings.app.markdownMaxWidth", defaultValue: "Markdown Viewer Max Width")
                )
            }
            SettingsCardDivider()

            // Canvas Pane Gap
            SettingsCardRow(
                configurationReview: .json("canvas.paneGap"),
                String(localized: "settings.app.canvasPaneGap", defaultValue: "Canvas Pane Gap"),
                subtitle: String(localized: "settings.app.canvasPaneGap.subtitle", defaultValue: "Spacing between panes in the canvas layout, in points. Snapping, tidy, and new-pane placement all use this one gap."),
                controlWidth: Self.columnWidth
            ) {
                Stepper(
                    value: Binding(get: { canvasPaneGap.current }, set: { canvasPaneGap.set($0) }),
                    in: 0...64,
                    step: 2
                ) {
                    Text(verbatim: "\(canvasPaneGap.current)")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCanvasPaneGapStepper")
                .accessibilityLabel(
                    String(localized: "settings.app.canvasPaneGap", defaultValue: "Canvas Pane Gap")
                )
            }
            SettingsCardDivider()

            // Canvas Snapping
            SettingsCardRow(
                configurationReview: .json("canvas.snappingEnabled"),
                String(localized: "settings.app.canvasSnapping", defaultValue: "Canvas Snapping"),
                subtitle: String(localized: "settings.app.canvasSnapping.subtitle", defaultValue: "Snap pane drags and resizes to neighbor edges and the pane gap. Hold Command to suspend snapping for one gesture.")
            ) {
                Toggle("", isOn: Binding(get: { canvasSnapping.current }, set: { canvasSnapping.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsCanvasSnappingToggle")
            }
            SettingsCardDivider()

            // Markdown Viewer Font Family
            SettingsCardRow(
                configurationReview: .json("markdown.fontFamily"),
                String(localized: "settings.app.markdownFontFamily", defaultValue: "Markdown Viewer Font"),
                subtitle: String(localized: "settings.app.markdownFontFamily.subtitle", defaultValue: "Default body font family for newly opened markdown viewers. Leave empty for the system markdown font stack.")
            ) {
                TextField(
                    String(localized: "settings.app.markdownFontFamily.placeholder", defaultValue: "System"),
                    text: Binding(get: { markdownFontFamily.current }, set: { markdownFontFamily.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("SettingsMarkdownFontFamilyTextField")
            }
            SettingsCardDivider()

            // File Editor Word Wrap
            SettingsCardRow(
                configurationReview: .json("fileEditor.wordWrap"),
                String(localized: "settings.app.fileEditorWordWrap", defaultValue: "File Editor Word Wrap"),
                subtitle: String(localized: "settings.app.fileEditorWordWrap.subtitle", defaultValue: "Wrap long lines at the editor's right edge instead of scrolling horizontally. Applies to the plain-text file editor.")
            ) {
                Toggle("", isOn: Binding(get: { fileEditorWordWrap.current }, set: { fileEditorWordWrap.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsFileEditorWordWrapToggle")
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("fileEditor.syntaxHighlighting"),
                String(localized: "settings.app.fileEditorSyntaxHighlighting", defaultValue: "File Editor Syntax Highlighting"),
                subtitle: String(localized: "settings.app.fileEditorSyntaxHighlighting.subtitle", defaultValue: "Color keywords, strings, and other tokens in the built-in file editor.")
            ) {
                Toggle("", isOn: Binding(get: { fileEditorSyntaxHighlighting.current }, set: { fileEditorSyntaxHighlighting.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsFileEditorSyntaxHighlightingToggle")
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("fileEditor.lineNumbers"),
                String(localized: "settings.app.fileEditorLineNumbers", defaultValue: "File Editor Line Numbers"),
                subtitle: String(localized: "settings.app.fileEditorLineNumbers.subtitle", defaultValue: "Show a line-number gutter beside the built-in file editor.")
            ) {
                Toggle("", isOn: Binding(get: { fileEditorLineNumbers.current }, set: { fileEditorLineNumbers.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsFileEditorLineNumbersToggle")
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("fileEditor.indentGuides"),
                String(localized: "settings.app.fileEditorIndentGuides", defaultValue: "File Editor Indent Guides"),
                subtitle: String(localized: "settings.app.fileEditorIndentGuides.subtitle", defaultValue: "Draw vertical guides at indent columns in the built-in file editor.")
            ) {
                Toggle("", isOn: Binding(get: { fileEditorIndentGuides.current }, set: { fileEditorIndentGuides.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsFileEditorIndentGuidesToggle")
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("fileEditor.currentLineHighlight"),
                String(localized: "settings.app.fileEditorCurrentLineHighlight", defaultValue: "File Editor Current Line Highlight"),
                subtitle: String(localized: "settings.app.fileEditorCurrentLineHighlight.subtitle", defaultValue: "Highlight the line that contains the caret when nothing is selected.")
            ) {
                Toggle("", isOn: Binding(get: { fileEditorCurrentLineHighlight.current }, set: { fileEditorCurrentLineHighlight.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsFileEditorCurrentLineHighlightToggle")
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("fileEditor.tabWidth"),
                String(localized: "settings.app.fileEditorTabWidth", defaultValue: "File Editor Tab Width"),
                subtitle: String(localized: "settings.app.fileEditorTabWidth.subtitle", defaultValue: "Columns per tab stop, used by indent guides.")
            ) {
                Stepper(
                    value: Binding(
                        get: { fileEditorTabWidth.current },
                        set: { fileEditorTabWidth.set($0) }
                    ),
                    in: FileEditorCatalogSection.supportedTabWidthRange
                ) {
                    Text("\(fileEditorTabWidth.current)")
                        .monospacedDigit()
                }
                .accessibilityLabel(
                    String(localized: "settings.app.fileEditorTabWidth", defaultValue: "File Editor Tab Width")
                )
                .accessibilityIdentifier("SettingsFileEditorTabWidthStepper")
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
                subtitle: String(localized: "settings.app.reorderOnNotification.modeSubtitle", defaultValue: "Move workspaces to the top when they receive a notification. Agent Activity also moves them when you send a prompt or an agent finishes a turn, needs input, or fails, but never while you point at the sidebar. Off keeps shortcut positions stable."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { reorder.current }, set: { reorder.set($0) })) {
                    Text(String(localized: "settings.app.reorderOnNotification.mode.off", defaultValue: "Off")).tag(WorkspaceAutoReorderMode.off)
                    Text(String(localized: "settings.app.reorderOnNotification.mode.notifications", defaultValue: "Notifications")).tag(WorkspaceAutoReorderMode.notifications)
                    Text(String(localized: "settings.app.reorderOnNotification.mode.agentActivity", defaultValue: "Agent Activity")).tag(WorkspaceAutoReorderMode.agentActivity)
                }
                .labelsHidden()
                .pickerStyle(.menu)
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
                Toggle("", isOn: Binding(get: { menuBarOnly.current }, set: { enabled in
                    if hostActions.setMenuBarOnly(enabled) {
                        menuBarOnly.acceptCommittedValue(enabled)
                    }
                }))
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
                subtitle: String(localized: "settings.notifications.paneRing.subtitle", defaultValue: "Show a ring around panes with unread notifications.")
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
                subtitle: String(localized: "settings.notifications.paneFlash.subtitle", defaultValue: "Briefly flash an outline when cmux highlights a pane.")
            ) {
                Toggle("", isOn: Binding(get: { paneFlash.current }, set: { paneFlash.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Pane Flash: Double Blink
            SettingsCardRow(
                configurationReview: .json("notifications.paneFlashDoubleBlink"),
                String(localized: "settings.notifications.paneFlashDoubleBlink.title", defaultValue: "Double Blink"),
                subtitle: String(localized: "settings.notifications.paneFlashDoubleBlink.subtitle", defaultValue: "Blink the pane flash twice instead of one short pulse.")
            ) {
                Toggle("", isOn: Binding(get: { paneFlashDoubleBlink.current }, set: { paneFlashDoubleBlink.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!paneFlash.current)
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("notifications.paneFlashThemeColor"),
                String(localized: "settings.notifications.paneFlashThemeColor.title", defaultValue: "Use Theme Foreground"),
                subtitle: String(localized: "settings.notifications.paneFlashThemeColor.subtitle", defaultValue: "Use the terminal theme foreground for flashes; unread rings stay cmux blue.")
            ) {
                Toggle("", isOn: Binding(get: { paneFlashThemeColor.current }, set: { paneFlashThemeColor.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!paneFlash.current)
            }
            SettingsCardDivider()

            // Agent: Needs Permission
            SettingsCardRow(
                configurationReview: .json("notifications.agentPermissionPrompt"),
                String(localized: "settings.notifications.agentPermissionPrompt.title", defaultValue: "Agent Needs Permission"),
                subtitle: String(localized: "settings.notifications.agentPermissionPrompt.subtitle", defaultValue: "Notify when an agent is blocked waiting for your permission to run a tool.")
            ) {
                Toggle("", isOn: Binding(get: { agentPermissionPrompt.current }, set: { agentPermissionPrompt.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Agent: Turn Complete
            SettingsCardRow(
                configurationReview: .json("notifications.agentTurnComplete"),
                String(localized: "settings.notifications.agentTurnComplete.title", defaultValue: "Agent Finished"),
                subtitle: String(localized: "settings.notifications.agentTurnComplete.subtitle", defaultValue: "When to notify that an agent finished. When idle waits until background tasks and scheduled wakeups drain.")
            ) {
                Picker("", selection: Binding(get: { agentTurnComplete.current }, set: { agentTurnComplete.set($0) })) {
                    Text(String(localized: "settings.notifications.agentTurnComplete.option.whenIdle", defaultValue: "When idle")).tag("whenIdle")
                    Text(String(localized: "settings.notifications.agentTurnComplete.option.always", defaultValue: "Always")).tag("always")
                    Text(String(localized: "settings.notifications.agentTurnComplete.option.never", defaultValue: "Never")).tag("never")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            // Agent: Idle Reminder
            SettingsCardRow(
                configurationReview: .json("notifications.agentIdleReminder"),
                String(localized: "settings.notifications.agentIdleReminder.title", defaultValue: "Agent Waiting for Input"),
                subtitle: String(localized: "settings.notifications.agentIdleReminder.subtitle", defaultValue: "Notify when an agent has been idle waiting for your input. Suppressed while background work is still running.")
            ) {
                Toggle("", isOn: Binding(get: { agentIdleReminder.current }, set: { agentIdleReminder.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }

            // Desktop Notifications
            SettingsCardDivider()
            DesktopNotificationsSettingsRow(
                state: desktopNotifications.current,
                requestAuthorization: { hostActions.requestNotificationAuthorization() },
                openSystemSettings: { hostActions.openSystemNotificationSettings() },
                sendTest: { hostActions.sendTestNotification() }
            )
            SettingsCardDivider()

            NotificationSoundGlobalRow(
                soundModel: soundName,
                customFileModel: customSoundFile,
                hostActions: hostActions
            )
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("notifications.soundWhenFocused"),
                String(localized: "settings.notifications.soundWhenFocused.title", defaultValue: "Sound for Focused Pane"),
                subtitle: String(localized: "settings.notifications.soundWhenFocused.subtitle", defaultValue: "Play the notification sound even when the pane that notified is already focused. When off, a focused pane shows its ring without a sound.")
            ) {
                Toggle("", isOn: Binding(get: { soundWhenFocused.current }, set: { soundWhenFocused.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("notifications.soundOverrides"),
                String(localized: "settings.notifications.soundOverrides.title", defaultValue: "Per-Agent Notification Sounds"),
                subtitle: String(localized: "settings.notifications.soundOverrides.subtitle", defaultValue: "Override the sound for a specific agent and alert type."),
                verticalAlignment: .top,
                trailingFillsWidth: true
            ) {
                NotificationSoundOverridesView(
                    parsedOverrides: soundOverridesModel.parsed ?? .empty,
                    isPersistedValueMalformed: soundOverridesModel.isMalformed,
                    onChange: { value, agentID, alertType in
                        guard var overrides = NotificationSoundOverrides(
                            jsonString: soundOverrides.current
                        ) else {
                            // Never replace a malformed persisted matrix with
                            // an empty one while editing a different cell.
                            return
                        }
                        guard overrides.set(value, forAgentID: agentID, alertType: alertType) else {
                            return
                        }
                        let encoded = overrides.jsonString
                        // A non-empty matrix must never be replaced by the
                        // serializer's failure sentinel when a cell contains
                        // an oversized value.
                        guard overrides.isEmpty || encoded != "{}" else { return }
                        soundOverrides.set(encoded)
                    },
                    hostActions: hostActions,
                    agents: soundAgentCache.agents ?? []
                )
                .frame(minWidth: 510, maxWidth: .infinity, alignment: .leading)
            }
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
                subtitle: telemetryManagedByPolicy
                    ? String(localized: "settings.managedByOrganization", defaultValue: "Managed by your organization")
                    : (telemetryAtAppear != nil && telemetry.current != telemetryAtAppear)
                        ? String(localized: "settings.app.telemetry.subtitleChanged", defaultValue: "Change takes effect on next launch.")
                        : String(localized: "settings.app.telemetry.subtitle", defaultValue: "Share anonymized crash and usage data to help improve cmux.")
            ) {
                Toggle("", isOn: Binding(get: { telemetry.current && !telemetryManagedByPolicy }, set: { telemetry.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(telemetryManagedByPolicy)
            }
            SettingsCardDivider()

            // Warn Before Quit
            SettingsCardRow(
                configurationReview: .json("app.confirmQuit", "app.warnBeforeQuit"),
                String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"),
                subtitle: String(localized: "settings.app.warnBeforeQuit.subtitle", defaultValue: "Choose when quitting with Command-Q asks for confirmation. Dirty Only asks only when a workspace would ask before closing."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { confirmQuit.current }, set: { confirmQuit.set($0) })) {
                    // Labels mirror legacy QuitConfirmationMode.localizedSettingsTitle.
                    Text(String(localized: "settings.app.confirmQuit.always", defaultValue: "Always")).tag(ConfirmQuitMode.always)
                    Text(String(localized: "settings.app.confirmQuit.dirtyOnly", defaultValue: "Dirty Only")).tag(ConfirmQuitMode.dirtyOnly)
                    Text(String(localized: "settings.app.confirmQuit.never", defaultValue: "Never")).tag(ConfirmQuitMode.never)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            SettingsCardDivider()

            // Warn Before Closing Tab
            SettingsCardRow(
                configurationReview: .json(catalog.app.warnBeforeClosingTab.id),
                catalog.app.warnBeforeClosingTab.userFacing!.title,
                subtitle: String(localized: "settings.app.warnBeforeClosingTab.subtitle", defaultValue: "Closing a tab asks for confirmation first.")
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
                subtitle: warnCloseXSubtitle(hideCloseButton: hideCloseButton.current)
            ) {
                Toggle("", isOn: Binding(get: { warnCloseX.current }, set: { warnCloseX.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(hideCloseButton.current)
            }
            SettingsCardDivider()

            // Warn Before Closing Workspace
            SettingsCardRow(
                configurationReview: .json(catalog.app.warnBeforeClosingWorkspace.id),
                catalog.app.warnBeforeClosingWorkspace.userFacing!.title,
                subtitle: warnCloseWorkspace.current
                    ? String(localized: "settings.app.warnBeforeClosingWorkspace.subtitleOn", defaultValue: "Show a confirmation before closing a workspace with a running process, or several workspaces at once.")
                    : String(localized: "settings.app.warnBeforeClosingWorkspace.subtitleOff", defaultValue: "Workspaces close immediately without confirmation. Pinned workspaces still ask.")
            ) {
                Toggle("", isOn: Binding(get: { warnCloseWorkspace.current }, set: { warnCloseWorkspace.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Warn Before Closing Window
            SettingsCardRow(
                configurationReview: .json(catalog.app.warnBeforeClosingWindow.id),
                catalog.app.warnBeforeClosingWindow.userFacing!.title,
                subtitle: warnCloseWindow.current
                    ? String(localized: "settings.app.warnBeforeClosingWindow.subtitleOn", defaultValue: "Show a confirmation before closing a window with a running process, or all of a window's workspaces at once.")
                    : String(localized: "settings.app.warnBeforeClosingWindow.subtitleOff", defaultValue: "Windows close immediately without confirmation.")
            ) {
                Toggle("", isOn: Binding(get: { warnCloseWindow.current }, set: { warnCloseWindow.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Hide Tab Close Button
            SettingsCardRow(
                configurationReview: .json(catalog.app.hideTabCloseButton.id),
                catalog.app.hideTabCloseButton.userFacing!.title,
                subtitle: String(localized: "settings.app.hideTabCloseButton.subtitle", defaultValue: "Removes the close button from tabs.")
            ) {
                Toggle("", isOn: Binding(get: { hideCloseButton.current }, set: { hideCloseButton.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
            }
            SettingsCardDivider()

            // Rename Selects Existing Name
            SettingsCardRow(
                configurationReview: .json(catalog.app.renameSelectsExistingName.id),
                catalog.app.renameSelectsExistingName.userFacing!.title,
                subtitle: String(localized: "settings.app.renameSelectsName.subtitle", defaultValue: "Renaming from the command palette selects the current name.")
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
                subtitle: String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitle", defaultValue: "Includes terminal, browser, and Markdown surfaces from every workspace in command palette results.")
            ) {
                Toggle("", isOn: Binding(get: { paletteAllSurfaces.current }, set: { paletteAllSurfaces.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("CommandPaletteSearchAllSurfacesToggle")
            }
        }
    }

}
