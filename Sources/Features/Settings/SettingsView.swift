//
//  SettingsView.swift
//  cmux
//
//  Created by Gale Williams on 3/16/26.
//

import Bonsplit
import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    // MARK: SwiftUI Properties

    @AppStorage(LanguageSettings.languageKey) private var appLanguage = LanguageSettings.defaultLanguage.rawValue
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage(AppIconSettings.modeKey) private var appIconMode = AppIconSettings.defaultMode.rawValue
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(ClaudeCodeIntegrationSettings.hooksEnabledKey)
    private var claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
    @AppStorage(TelemetrySettings.sendAnonymousTelemetryKey)
    private var sendAnonymousTelemetry = TelemetrySettings.defaultSendAnonymousTelemetry
    @AppStorage("cmuxPortBase") private var cmuxPortBase = 9100
    @AppStorage("cmuxPortRange") private var cmuxPortRange = 10
    @AppStorage(BrowserSearchSettings.searchEngineKey) private var browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) private var browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @AppStorage(BrowserThemeSettings.modeKey) private var browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
    @AppStorage(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey) private var openTerminalLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInCmuxBrowser
    @AppStorage(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)
    private var interceptTerminalOpenCommandInCmuxBrowser = BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInCmuxBrowserValue()
    @AppStorage(BrowserLinkOpenSettings.browserHostWhitelistKey) private var browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
    @AppStorage(BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
    private var browserExternalOpenPatterns = BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns
    @AppStorage(BrowserInsecureHTTPSettings.allowlistKey) private var browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
    @AppStorage(NotificationSoundSettings.key) private var notificationSound = NotificationSoundSettings.defaultValue
    @AppStorage(NotificationSoundSettings.customFilePathKey)
    private var notificationSoundCustomFilePath = NotificationSoundSettings.defaultCustomFilePath
    @AppStorage(NotificationSoundSettings.customCommandKey) private var notificationCustomCommand = NotificationSoundSettings.defaultCustomCommand
    @AppStorage(NotificationBadgeSettings.dockBadgeEnabledKey) private var notificationDockBadgeEnabled = NotificationBadgeSettings.defaultDockBadgeEnabled
    @AppStorage(NotificationPaneRingSettings.enabledKey) private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    @AppStorage(NotificationPaneFlashSettings.enabledKey) private var notificationPaneFlashEnabled = NotificationPaneFlashSettings.defaultEnabled
    @AppStorage(MenuBarExtraSettings.showInMenuBarKey) private var showMenuBarExtra = MenuBarExtraSettings.defaultShowInMenuBar
    @AppStorage(QuitWarningSettings.warnBeforeQuitKey) private var warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    private var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey)
    private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
    @AppStorage(WorkspacePlacementSettings.placementKey) private var newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
    @AppStorage(WorkspaceAutoReorderSettings.key) private var workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
    @AppStorage(SidebarWorkspaceDetailSettings.hideAllDetailsKey)
    private var sidebarHideAllDetails = SidebarWorkspaceDetailSettings.defaultHideAllDetails
    @AppStorage(SidebarWorkspaceDetailSettings.showNotificationMessageKey)
    private var sidebarShowNotificationMessage = SidebarWorkspaceDetailSettings.defaultShowNotificationMessage
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage("sidebarShowBranchDirectory") private var sidebarShowBranchDirectory = true
    @AppStorage("sidebarShowPullRequest") private var sidebarShowPullRequest = true
    @AppStorage(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
    private var openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
    @AppStorage(ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
    private var showShortcutHintsOnCommandHold = ShortcutHintDebugSettings.defaultShowHintsOnCommandHold
    @AppStorage("sidebarShowPorts") private var sidebarShowPorts = true
    @AppStorage("sidebarShowLog") private var sidebarShowLog = true
    @AppStorage("sidebarShowProgress") private var sidebarShowProgress = true
    @AppStorage("sidebarShowStatusPills") private var sidebarShowMetadata = true
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @ObservedObject private var notificationStore = TerminalNotificationStore.shared
    @State private var shortcutResetToken = UUID()
    @State private var topBlurOpacity: Double = 0
    @State private var topBlurBaselineOffset: CGFloat?
    @State private var settingsTitleLeadingInset: CGFloat = 92
    @State private var showClearBrowserHistoryConfirmation = false
    @State private var showOpenAccessConfirmation = false
    @State private var pendingOpenAccessMode: SocketControlMode?
    @State private var browserHistoryEntryCount: Int = 0
    @State private var browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
    @State private var socketPasswordDraft = ""
    @State private var socketPasswordStatusMessage: String?
    @State private var socketPasswordStatusIsError = false
    @State private var notificationCustomSoundStatusMessage: String?
    @State private var notificationCustomSoundStatusIsError = false
    @State private var showNotificationCustomSoundErrorAlert = false
    @State private var notificationCustomSoundErrorAlertMessage = ""
    @State private var telemetryValueAtLaunch = TelemetrySettings.enabledForCurrentLaunch
    @State private var showLanguageRestartAlert = false
    @State private var isResettingSettings = false
    @State private var workspaceTabDefaultEntries = WorkspaceTabColorSettings.defaultPaletteWithOverrides()
    @State private var workspaceTabCustomColors = WorkspaceTabColorSettings.customColors()

    // MARK: Properties

    private let contentTopInset: CGFloat = 8
    private let pickerColumnWidth: CGFloat = 196
    private let notificationSoundControlWidth: CGFloat = 280

    // MARK: Computed Properties

    private var selectedWorkspacePlacement: NewWorkspacePlacement {
        NewWorkspacePlacement(rawValue: newWorkspacePlacement) ?? WorkspacePlacementSettings.defaultPlacement
    }

    private var selectedSidebarActiveTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: sidebarActiveTabIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarActiveTabIndicatorStyle.rawValue },
            set: { sidebarActiveTabIndicatorStyle = $0 }
        )
    }

    private var selectedSocketControlMode: SocketControlMode {
        SocketControlSettings.migrateMode(socketControlMode)
    }

    private var selectedBrowserThemeMode: BrowserThemeMode {
        BrowserThemeSettings.mode(for: browserThemeMode)
    }

    private var browserThemeModeSelection: Binding<String> {
        Binding(
            get: { browserThemeMode },
            set: { newValue in
                browserThemeMode = BrowserThemeSettings.mode(for: newValue).rawValue
            }
        )
    }

    private var socketModeSelection: Binding<String> {
        Binding(
            get: { socketControlMode },
            set: { newValue in
                let normalized = SocketControlSettings.migrateMode(newValue)
                if normalized == .allowAll, selectedSocketControlMode != .allowAll {
                    pendingOpenAccessMode = normalized
                    showOpenAccessConfirmation = true
                    return
                }
                socketControlMode = normalized.rawValue
                if normalized != .password {
                    socketPasswordStatusMessage = nil
                    socketPasswordStatusIsError = false
                }
            }
        )
    }

    private var settingsSidebarTintLightBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: sidebarTintHexLight ?? sidebarTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarTintHexLight = nsColor.hexString()
            }
        )
    }

    private var settingsSidebarTintDarkBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: sidebarTintHexDark ?? sidebarTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarTintHexDark = nsColor.hexString()
            }
        )
    }

    private var hasSocketPasswordConfigured: Bool {
        SocketControlPasswordStore.hasConfiguredPassword()
    }

    private var browserHistorySubtitle: String {
        switch browserHistoryEntryCount {
            case 0:
                String(localized: "settings.browser.history.subtitleEmpty", defaultValue: "No saved pages yet.")
            case 1:
                String(localized: "settings.browser.history.subtitleOne", defaultValue: "1 saved page appears in omnibar suggestions.")
            default:
                String(localized: "settings.browser.history.subtitleMany", defaultValue: "\(browserHistoryEntryCount) saved pages appear in omnibar suggestions.")
        }
    }

    private var browserInsecureHTTPAllowlistHasUnsavedChanges: Bool {
        browserInsecureHTTPAllowlistDraft != browserInsecureHTTPAllowlist
    }

    private var hasCustomNotificationSoundFilePath: Bool {
        !notificationSoundCustomFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var notificationSoundCustomFileDisplayName: String {
        guard hasCustomNotificationSoundFilePath else {
            return String(
                localized: "settings.notifications.sound.custom.file.none",
                defaultValue: "No file selected"
            )
        }
        return URL(fileURLWithPath: notificationSoundCustomFilePath).lastPathComponent
    }

    private var canPreviewNotificationSound: Bool {
        switch notificationSound {
            case "none":
                false
            case NotificationSoundSettings.customFileValue:
                hasCustomNotificationSoundFilePath
            default:
                true
        }
    }

    private var notificationPermissionStatusText: String {
        notificationStore.authorizationState.statusLabel
    }

    private var notificationPermissionStatusColor: Color {
        switch notificationStore.authorizationState {
            case .authorized, .provisional, .ephemeral:
                .green
            case .denied:
                .red
            case .unknown, .notDetermined:
                .secondary
        }
    }

    private var notificationPermissionSubtitle: String {
        switch notificationStore.authorizationState {
            case .unknown, .notDetermined:
                "Desktop notifications are not enabled yet."
            case .authorized:
                "Desktop notifications are enabled."
            case .denied:
                "Desktop notifications are disabled in System Settings."
            case .provisional:
                "Desktop notifications are enabled with quiet delivery."
            case .ephemeral:
                "Desktop notifications are temporarily enabled."
        }
    }

    private var notificationPermissionActionTitle: String {
        switch notificationStore.authorizationState {
            case .unknown, .notDetermined:
                "Enable"
            case .authorized, .denied, .provisional, .ephemeral:
                "Open Settings"
        }
    }

    // MARK: Content Properties

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsSectionHeader(title: String(localized: "settings.section.app", defaultValue: "App"))
                        SettingsCard {
                            SettingsCardRow(
                                String(localized: "settings.app.language", defaultValue: "Language"),
                                subtitle: appLanguage != LanguageSettings.languageAtLaunch.rawValue
                                    ? String(localized: "settings.app.language.restartSubtitle", defaultValue: "Restart cmux to apply")
                                    : nil,
                                controlWidth: pickerColumnWidth
                            ) {
                                Picker("", selection: $appLanguage) {
                                    ForEach(AppLanguage.allCases) { lang in
                                        Text(lang.displayName).tag(lang.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .onChange(of: appLanguage) { _ in
                                    guard !isResettingSettings else { return }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                                        // Re-check current value to handle rapid changes
                                        let current = appLanguage
                                        if let lang = AppLanguage(rawValue: current) {
                                            LanguageSettings.apply(lang)
                                        }
                                        if current != LanguageSettings.languageAtLaunch.rawValue {
                                            showLanguageRestartAlert = true
                                        }
                                    }
                                }
                            }

                            SettingsCardDivider()

                            ThemePickerRow(
                                selectedMode: appearanceMode,
                                onSelect: { mode in
                                    appearanceMode = mode.rawValue
                                }
                            )

                            SettingsCardDivider()

                            AppIconPickerRow(
                                selectedMode: appIconMode,
                                onSelect: { mode in
                                    appIconMode = mode.rawValue
                                    AppIconSettings.applyIcon(mode)
                                }
                            )

                            SettingsCardDivider()

                            SettingsPickerRow(
                                String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"),
                                subtitle: selectedWorkspacePlacement.description,
                                controlWidth: pickerColumnWidth,
                                selection: $newWorkspacePlacement
                            ) {
                                ForEach(NewWorkspacePlacement.allCases) { placement in
                                    Text(placement.displayName).tag(placement.rawValue)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"),
                                subtitle: String(localized: "settings.app.reorderOnNotification.subtitle", defaultValue: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions.")
                            ) {
                                Toggle("", isOn: $workspaceAutoReorder)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.dockBadge", defaultValue: "Dock Badge"),
                                subtitle: String(localized: "settings.app.dockBadge.subtitle", defaultValue: "Show unread count on app icon (Dock and Cmd+Tab).")
                            ) {
                                Toggle("", isOn: $notificationDockBadgeEnabled)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar"),
                                subtitle: String(localized: "settings.app.showInMenuBar.subtitle", defaultValue: "Keep cmux in the menu bar for unread notifications and quick actions.")
                            ) {
                                Toggle("", isOn: $showMenuBarExtra)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .accessibilityLabel(
                                        String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar")
                                    )
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.notifications.paneRing.title", defaultValue: "Unread Pane Ring"),
                                subtitle: String(localized: "settings.notifications.paneRing.subtitle", defaultValue: "Show a blue ring around panes with unread notifications.")
                            ) {
                                Toggle("", isOn: $notificationPaneRingEnabled)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .accessibilityLabel(
                                        String(localized: "settings.notifications.paneRing.title", defaultValue: "Unread Pane Ring")
                                    )
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.notifications.paneFlash.title", defaultValue: "Pane Flash"),
                                subtitle: String(localized: "settings.notifications.paneFlash.subtitle", defaultValue: "Briefly flash a blue outline when cmux highlights a pane.")
                            ) {
                                Toggle("", isOn: $notificationPaneFlashEnabled)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .accessibilityLabel(
                                        String(localized: "settings.notifications.paneFlash.title", defaultValue: "Pane Flash")
                                    )
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                "Desktop Notifications",
                                subtitle: notificationPermissionSubtitle
                            ) {
                                HStack(spacing: 6) {
                                    Text(notificationPermissionStatusText)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(notificationPermissionStatusColor)
                                        .frame(width: 98, alignment: .trailing)

                                    Button(notificationPermissionActionTitle) {
                                        handleNotificationPermissionAction()
                                    }
                                    .controlSize(.small)

                                    Button("Send Test") {
                                        notificationStore.sendSettingsTestNotification()
                                    }
                                    .controlSize(.small)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.notifications.sound.title", defaultValue: "Notification Sound"),
                                subtitle: String(localized: "settings.notifications.sound.subtitle", defaultValue: "Sound played when a notification arrives."),
                                controlWidth: notificationSoundControlWidth
                            ) {
                                VStack(alignment: .trailing, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Picker("", selection: $notificationSound) {
                                            ForEach(NotificationSoundSettings.systemSounds, id: \.value) { sound in
                                                Text(sound.label).tag(sound.value)
                                            }
                                        }
                                        .labelsHidden()
                                        Button {
                                            previewNotificationSound()
                                        } label: {
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 9))
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(!canPreviewNotificationSound)
                                    }

                                    if notificationSound == NotificationSoundSettings.customFileValue {
                                        HStack(spacing: 6) {
                                            Text(notificationSoundCustomFileDisplayName)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .frame(width: 170, alignment: .trailing)
                                            Button(
                                                String(
                                                    localized: "settings.notifications.sound.custom.choose.button",
                                                    defaultValue: "Choose..."
                                                )
                                            ) {
                                                chooseNotificationSoundFile()
                                            }
                                            .controlSize(.small)
                                            Button(
                                                String(
                                                    localized: "settings.notifications.sound.custom.clear.button",
                                                    defaultValue: "Clear"
                                                )
                                            ) {
                                                notificationSoundCustomFilePath = NotificationSoundSettings.defaultCustomFilePath
                                                refreshNotificationCustomSoundStatus()
                                            }
                                            .controlSize(.small)
                                            .disabled(!hasCustomNotificationSoundFilePath)
                                        }
                                        if let notificationCustomSoundStatusMessage {
                                            Text(notificationCustomSoundStatusMessage)
                                                .font(.system(size: 11))
                                                .foregroundStyle(notificationCustomSoundStatusIsError ? Color.red : Color.secondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.trailing)
                                                .frame(width: 260, alignment: .trailing)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                "Notification Command",
                                subtitle: "Run a shell command when a notification arrives. $CMUX_NOTIFICATION_TITLE, $CMUX_NOTIFICATION_SUBTITLE, $CMUX_NOTIFICATION_BODY are set."
                            ) {
                                TextField("say \"done\"", text: $notificationCustomCommand)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.telemetry", defaultValue: "Send anonymous telemetry"),
                                subtitle: sendAnonymousTelemetry != telemetryValueAtLaunch
                                    ? String(localized: "settings.app.telemetry.subtitleChanged", defaultValue: "Change takes effect on next launch.")
                                    : String(localized: "settings.app.telemetry.subtitle", defaultValue: "Share anonymized crash and usage data to help improve cmux.")
                            ) {
                                Toggle("", isOn: $sendAnonymousTelemetry)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"),
                                subtitle: warnBeforeQuitShortcut
                                    ? String(localized: "settings.app.warnBeforeQuit.subtitleOn", defaultValue: "Show a confirmation before quitting with Cmd+Q.")
                                    : String(localized: "settings.app.warnBeforeQuit.subtitleOff", defaultValue: "Cmd+Q quits immediately without confirmation.")
                            ) {
                                Toggle("", isOn: $warnBeforeQuitShortcut)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.renameSelectsName", defaultValue: "Rename Selects Existing Name"),
                                subtitle: commandPaletteRenameSelectAllOnFocus
                                    ? String(localized: "settings.app.renameSelectsName.subtitleOn", defaultValue: "Command Palette rename starts with all text selected.")
                                    : String(localized: "settings.app.renameSelectsName.subtitleOff", defaultValue: "Command Palette rename keeps the caret at the end.")
                            ) {
                                Toggle("", isOn: $commandPaletteRenameSelectAllOnFocus)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces"),
                                subtitle: commandPaletteSearchAllSurfaces
                                    ? String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOn", defaultValue: "Cmd+P also matches terminal, browser, and markdown surfaces across workspaces.")
                                    : String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOff", defaultValue: "Cmd+P matches workspace rows only.")
                            ) {
                                Toggle("", isOn: $commandPaletteSearchAllSurfaces)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .accessibilityIdentifier("CommandPaletteSearchAllSurfacesToggle")
                                    .accessibilityLabel(
                                        String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces")
                                    )
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.hideAllSidebarDetails", defaultValue: "Hide All Sidebar Details"),
                                subtitle: sidebarHideAllDetails
                                    ? String(localized: "settings.app.hideAllSidebarDetails.subtitleOn", defaultValue: "Show only the workspace title row. Overrides the detail toggles below.")
                                    : String(localized: "settings.app.hideAllSidebarDetails.subtitleOff", defaultValue: "Show secondary workspace details as controlled by the toggles below.")
                            ) {
                                Toggle("", isOn: $sidebarHideAllDetails)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            SettingsCardDivider()

                            SettingsPickerRow(
                                String(localized: "settings.app.sidebarBranchLayout", defaultValue: "Sidebar Branch Layout"),
                                subtitle: sidebarBranchVerticalLayout
                                    ? String(localized: "settings.app.sidebarBranchLayout.subtitleVertical", defaultValue: "Vertical: each branch appears on its own line.")
                                    : String(localized: "settings.app.sidebarBranchLayout.subtitleInline", defaultValue: "Inline: all branches share one line."),
                                controlWidth: pickerColumnWidth,
                                selection: $sidebarBranchVerticalLayout
                            ) {
                                Text(String(localized: "settings.app.sidebarBranchLayout.vertical", defaultValue: "Vertical")).tag(true)
                                Text(String(localized: "settings.app.sidebarBranchLayout.inline", defaultValue: "Inline")).tag(false)
                            }
                            .disabled(sidebarHideAllDetails)

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.showNotificationMessage", defaultValue: "Show Notification Message in Sidebar"),
                                subtitle: String(localized: "settings.app.showNotificationMessage.subtitle", defaultValue: "Display the latest notification message below the workspace title.")
                            ) {
                                Toggle("", isOn: $sidebarShowNotificationMessage)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .disabled(sidebarHideAllDetails)

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.showBranchDirectory", defaultValue: "Show Branch + Directory in Sidebar"),
                                subtitle: String(localized: "settings.app.showBranchDirectory.subtitle", defaultValue: "Display the built-in git branch and working-directory row.")
                            ) {
                                Toggle("", isOn: $sidebarShowBranchDirectory)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .disabled(sidebarHideAllDetails)

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar"),
                                subtitle: String(localized: "settings.app.showPullRequests.subtitle", defaultValue: "Display review items (PR/MR/etc.) with status, number, and clickable link.")
                            ) {
                                Toggle("", isOn: $sidebarShowPullRequest)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .disabled(sidebarHideAllDetails)

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.openSidebarPRLinks", defaultValue: "Open Sidebar PR Links in cmux Browser"),
                                subtitle: openSidebarPullRequestLinksInCmuxBrowser
                                    ? String(localized: "settings.app.openSidebarPRLinks.subtitleOn", defaultValue: "Clicks open inside cmux browser.")
                                    : String(localized: "settings.app.openSidebarPRLinks.subtitleOff", defaultValue: "Clicks open in your default browser.")
                            ) {
                                Toggle("", isOn: $openSidebarPullRequestLinksInCmuxBrowser)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .disabled(sidebarHideAllDetails)

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.showPorts", defaultValue: "Show Listening Ports in Sidebar"),
                                subtitle: String(localized: "settings.app.showPorts.subtitle", defaultValue: "Display detected listening ports for the active workspace.")
                            ) {
                                Toggle("", isOn: $sidebarShowPorts)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .disabled(sidebarHideAllDetails)

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.showLog", defaultValue: "Show Latest Log in Sidebar"),
                                subtitle: String(localized: "settings.app.showLog.subtitle", defaultValue: "Display the latest imperative log/status message.")
                            ) {
                                Toggle("", isOn: $sidebarShowLog)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .disabled(sidebarHideAllDetails)

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.showProgress", defaultValue: "Show Progress in Sidebar"),
                                subtitle: String(localized: "settings.app.showProgress.subtitle", defaultValue: "Display the built-in progress bar from set_progress.")
                            ) {
                                Toggle("", isOn: $sidebarShowProgress)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .disabled(sidebarHideAllDetails)

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.app.showMetadata", defaultValue: "Show Custom Metadata in Sidebar"),
                                subtitle: String(localized: "settings.app.showMetadata.subtitle", defaultValue: "Display custom metadata from report_meta/set_status and report_meta_block.")
                            ) {
                                Toggle("", isOn: $sidebarShowMetadata)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                            .disabled(sidebarHideAllDetails)
                        }

                        SettingsSectionHeader(title: String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors"))
                        SettingsCard {
                            SettingsPickerRow(
                                String(localized: "settings.workspaceColors.indicator", defaultValue: "Workspace Color Indicator"),
                                controlWidth: pickerColumnWidth,
                                selection: sidebarIndicatorStyleSelection
                            ) {
                                ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                                    Text(style.displayName).tag(style.rawValue)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardNote(String(localized: "settings.workspaceColors.paletteNote", defaultValue: "Customize the workspace color palette used by Sidebar > Workspace Color. \"Choose Custom Color...\" entries are persisted below."))

                            ForEach(Array(workspaceTabDefaultEntries.enumerated()), id: \.element.name) { index, entry in
                                if index > 0 {
                                    SettingsCardDivider()
                                }
                                SettingsCardRow(
                                    entry.name,
                                    subtitle: String(localized: "settings.workspaceColors.base", defaultValue: "Base: \(baseTabColorHex(for: entry.name))")
                                ) {
                                    HStack(spacing: 8) {
                                        ColorPicker(
                                            "",
                                            selection: defaultTabColorBinding(for: entry.name),
                                            supportsOpacity: false
                                        )
                                        .labelsHidden()
                                        .frame(width: 38)

                                        Text(entry.hex)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 76, alignment: .trailing)
                                    }
                                }
                            }

                            SettingsCardDivider()

                            if workspaceTabCustomColors.isEmpty {
                                SettingsCardNote(String(localized: "settings.workspaceColors.noCustomColors", defaultValue: "Custom colors: none yet. Use \"Choose Custom Color...\" from a workspace context menu."))
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(String(localized: "settings.workspaceColors.customColors", defaultValue: "Custom Colors"))
                                        .font(.system(size: 13, weight: .semibold))

                                    ForEach(workspaceTabCustomColors, id: \.self) { hex in
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                                                .frame(width: 11, height: 11)

                                            Text(hex)
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundStyle(.secondary)

                                            Spacer(minLength: 8)

                                            Button(String(localized: "settings.workspaceColors.remove", defaultValue: "Remove")) {
                                                removeWorkspaceCustomColor(hex)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.workspaceColors.resetPalette", defaultValue: "Reset Palette"),
                                subtitle: String(localized: "settings.workspaceColors.resetPalette.subtitle", defaultValue: "Restore built-in defaults and clear all custom colors.")
                            ) {
                                Button(String(localized: "settings.workspaceColors.resetPalette.button", defaultValue: "Reset")) {
                                    resetWorkspaceTabColors()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        SettingsSectionHeader(title: String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar Appearance"))
                        SettingsCard {
                            SettingsCardRow(
                                String(localized: "settings.sidebarAppearance.tintColorLight", defaultValue: "Light Mode Tint"),
                                subtitle: String(localized: "settings.sidebarAppearance.tintColorLight.subtitle", defaultValue: "Sidebar tint color when using light appearance.")
                            ) {
                                HStack(spacing: 8) {
                                    ColorPicker(
                                        String(localized: "settings.sidebarAppearance.tintColorLight.picker", defaultValue: "Light tint"),
                                        selection: settingsSidebarTintLightBinding,
                                        supportsOpacity: false
                                    )
                                    .labelsHidden()
                                    .frame(width: 38)

                                    Text(sidebarTintHexLight ?? String(localized: "settings.sidebarAppearance.defaultLabel", defaultValue: "Default"))
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 76, alignment: .trailing)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.sidebarAppearance.tintColorDark", defaultValue: "Dark Mode Tint"),
                                subtitle: String(localized: "settings.sidebarAppearance.tintColorDark.subtitle", defaultValue: "Sidebar tint color when using dark appearance.")
                            ) {
                                HStack(spacing: 8) {
                                    ColorPicker(
                                        String(localized: "settings.sidebarAppearance.tintColorDark.picker", defaultValue: "Dark tint"),
                                        selection: settingsSidebarTintDarkBinding,
                                        supportsOpacity: false
                                    )
                                    .labelsHidden()
                                    .frame(width: 38)

                                    Text(sidebarTintHexDark ?? String(localized: "settings.sidebarAppearance.defaultLabel", defaultValue: "Default"))
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 76, alignment: .trailing)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.sidebarAppearance.tintOpacity", defaultValue: "Tint Opacity"),
                                subtitle: String(localized: "settings.sidebarAppearance.tintOpacity.subtitle", defaultValue: "How strongly the tint color shows over the sidebar material.")
                            ) {
                                HStack(spacing: 8) {
                                    Slider(value: $sidebarTintOpacity, in: 0...1)
                                        .frame(width: 140)
                                    Text(String(format: "%.0f%%", sidebarTintOpacity * 100))
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.sidebarAppearance.reset", defaultValue: "Reset Sidebar Tint"),
                                subtitle: String(localized: "settings.sidebarAppearance.reset.subtitle", defaultValue: "Restore default sidebar appearance.")
                            ) {
                                Button(String(localized: "settings.sidebarAppearance.reset.button", defaultValue: "Reset")) {
                                    sidebarTintHexLight = nil
                                    sidebarTintHexDark = nil
                                    sidebarTintHex = SidebarTintDefaults.hex
                                    sidebarTintOpacity = SidebarTintDefaults.opacity
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        SettingsSectionHeader(title: String(localized: "settings.section.automation", defaultValue: "Automation"))
                        SettingsCard {
                            SettingsPickerRow(
                                String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"),
                                subtitle: selectedSocketControlMode.description,
                                controlWidth: pickerColumnWidth,
                                selection: socketModeSelection,
                                accessibilityId: "AutomationSocketModePicker"
                            ) {
                                ForEach(SocketControlMode.uiCases) { mode in
                                    Text(mode.displayName).tag(mode.rawValue)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardNote(String(localized: "settings.automation.socketMode.note", defaultValue: "Controls access to the local Unix socket for programmatic control. Choose a mode that matches your threat model."))
                            if selectedSocketControlMode == .password {
                                SettingsCardDivider()
                                SettingsCardRow(
                                    String(localized: "settings.automation.socketPassword", defaultValue: "Socket Password"),
                                    subtitle: hasSocketPasswordConfigured
                                        ? String(localized: "settings.automation.socketPassword.subtitleSet", defaultValue: "Stored in Application Support.")
                                        : String(localized: "settings.automation.socketPassword.subtitleUnset", defaultValue: "No password set. External clients will be blocked until one is configured.")
                                ) {
                                    HStack(spacing: 8) {
                                        SecureField(String(localized: "settings.automation.socketPassword.placeholder", defaultValue: "Password"), text: $socketPasswordDraft)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 170)
                                        Button(hasSocketPasswordConfigured ? String(localized: "settings.automation.socketPassword.change", defaultValue: "Change") : String(localized: "settings.automation.socketPassword.set", defaultValue: "Set")) {
                                            saveSocketPassword()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        if hasSocketPasswordConfigured {
                                            Button(String(localized: "settings.automation.socketPassword.clear", defaultValue: "Clear")) {
                                                clearSocketPassword()
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }
                                if let message = socketPasswordStatusMessage {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(socketPasswordStatusIsError ? Color.red : Color.secondary)
                                        .padding(.horizontal, 14)
                                        .padding(.bottom, 8)
                                }
                            }
                            if selectedSocketControlMode == .allowAll {
                                SettingsCardDivider()
                                Text(String(localized: "settings.automation.openAccessWarning", defaultValue: "Warning: Full open access makes the control socket world-readable/writable on this Mac and disables auth checks. Use only for local debugging."))
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            SettingsCardNote(String(localized: "settings.automation.socketOverrides.note", defaultValue: "Overrides: CMUX_SOCKET_ENABLE, CMUX_SOCKET_MODE, and CMUX_SOCKET_PATH (set CMUX_ALLOW_SOCKET_OVERRIDE=1 for stable/nightly builds)."))
                        }

                        SettingsCard {
                            SettingsCardRow(
                                String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration"),
                                subtitle: claudeCodeHooksEnabled
                                    ? String(localized: "settings.automation.claudeCode.subtitleOn", defaultValue: "Sidebar shows Claude session status and notifications.")
                                    : String(localized: "settings.automation.claudeCode.subtitleOff", defaultValue: "Claude Code runs without cmux integration.")
                            ) {
                                Toggle("", isOn: $claudeCodeHooksEnabled)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .accessibilityIdentifier("SettingsClaudeCodeHooksToggle")
                            }

                            SettingsCardDivider()

                            SettingsCardNote(String(localized: "settings.automation.claudeCode.note", defaultValue: "When enabled, cmux wraps the claude command to inject session tracking and notification hooks. Disable if you prefer to manage Claude Code hooks yourself."))
                        }

                        SettingsCard {
                            SettingsCardRow(String(localized: "settings.automation.portBase", defaultValue: "Port Base"), subtitle: String(localized: "settings.automation.portBase.subtitle", defaultValue: "Starting port for CMUX_PORT env var."), controlWidth: pickerColumnWidth) {
                                TextField("", value: $cmuxPortBase, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"), subtitle: String(localized: "settings.automation.portRange.subtitle", defaultValue: "Number of ports per workspace."), controlWidth: pickerColumnWidth) {
                                TextField("", value: $cmuxPortRange, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                            }

                            SettingsCardDivider()

                            SettingsCardNote(String(localized: "settings.automation.port.note", defaultValue: "Each workspace gets CMUX_PORT and CMUX_PORT_END env vars with a dedicated port range. New terminals inherit these values."))
                        }

                        SettingsSectionHeader(title: String(localized: "settings.section.browser", defaultValue: "Browser"))
                        SettingsCard {
                            SettingsPickerRow(
                                String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"),
                                subtitle: String(localized: "settings.browser.searchEngine.subtitle", defaultValue: "Used by the browser address bar when input is not a URL."),
                                controlWidth: pickerColumnWidth,
                                selection: $browserSearchEngine
                            ) {
                                ForEach(BrowserSearchEngine.allCases) { engine in
                                    Text(engine.displayName).tag(engine.rawValue)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow(String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions")) {
                                Toggle("", isOn: $browserSearchSuggestionsEnabled)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            SettingsCardDivider()

                            SettingsPickerRow(
                                String(localized: "settings.browser.theme", defaultValue: "Browser Theme"),
                                subtitle: selectedBrowserThemeMode == .system
                                    ? String(localized: "settings.browser.theme.subtitleSystem", defaultValue: "System follows app and macOS appearance.")
                                    : String(localized: "settings.browser.theme.subtitleForced", defaultValue: "\(selectedBrowserThemeMode.displayName) forces that color scheme for compatible pages."),
                                controlWidth: pickerColumnWidth,
                                selection: browserThemeModeSelection
                            ) {
                                ForEach(BrowserThemeMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode.rawValue)
                                }
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in cmux Browser"),
                                subtitle: String(localized: "settings.browser.openTerminalLinks.subtitle", defaultValue: "When off, links clicked in terminal output open in your default browser.")
                            ) {
                                Toggle("", isOn: $openTerminalLinksInCmuxBrowser)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"),
                                subtitle: String(localized: "settings.browser.interceptOpen.subtitle", defaultValue: "When off, `open https://...` and `open http://...` always use your default browser.")
                            ) {
                                Toggle("", isOn: $interceptTerminalOpenCommandInCmuxBrowser)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            if openTerminalLinksInCmuxBrowser || interceptTerminalOpenCommandInCmuxBrowser {
                                SettingsCardDivider()

                                VStack(alignment: .leading, spacing: 6) {
                                    SettingsCardRow(
                                        String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"),
                                        subtitle: String(localized: "settings.browser.hostWhitelist.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. Only these hosts open in cmux. Others open in your default browser. One host or wildcard per line (for example: example.com, *.internal.example). Leave empty to open all hosts in cmux.")
                                    ) {
                                        EmptyView()
                                    }

                                    TextEditor(text: $browserHostWhitelist)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minHeight: 60, maxHeight: 120)
                                        .scrollContentBackground(.hidden)
                                        .padding(6)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                        )
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 12)
                                }

                                SettingsCardDivider()

                                VStack(alignment: .leading, spacing: 6) {
                                    SettingsCardRow(
                                        String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"),
                                        subtitle: String(localized: "settings.browser.externalPatterns.subtitle", defaultValue: "Applies to terminal link clicks and intercepted `open https://...` calls. One rule per line. Plain text matches any URL substring, or prefix with `re:` for regex (for example: openai.com/usage, re:^https?://[^/]*\\.example\\.com/(billing|usage)).")
                                    ) {
                                        EmptyView()
                                    }

                                    TextEditor(text: $browserExternalOpenPatterns)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minHeight: 60, maxHeight: 120)
                                        .scrollContentBackground(.hidden)
                                        .padding(6)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                        )
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 12)
                                }
                            }

                            SettingsCardDivider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"))
                                    .font(.system(size: 13, weight: .semibold))

                                Text(String(localized: "settings.browser.httpAllowlist.description", defaultValue: "Controls which HTTP (non-HTTPS) hosts can open in cmux without a warning prompt. Defaults include localhost, 127.0.0.1, ::1, 0.0.0.0, and *.localtest.me."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                TextEditor(text: $browserInsecureHTTPAllowlistDraft)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .frame(minHeight: 86)
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color(nsColor: .textBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                    )
                                    .accessibilityIdentifier("SettingsBrowserHTTPAllowlistField")

                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .center, spacing: 10) {
                                        Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)

                                        Spacer(minLength: 0)

                                        Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                                            saveBrowserInsecureHTTPAllowlist()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                                        .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                                    }

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        HStack {
                                            Spacer(minLength: 0)
                                            Button(String(localized: "settings.browser.httpAllowlist.save", defaultValue: "Save")) {
                                                saveBrowserInsecureHTTPAllowlist()
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .disabled(!browserInsecureHTTPAllowlistHasUnsavedChanges)
                                            .accessibilityIdentifier("SettingsBrowserHTTPAllowlistSaveButton")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            SettingsCardDivider()

                            SettingsCardRow(String(localized: "settings.browser.history", defaultValue: "Browsing History"), subtitle: browserHistorySubtitle) {
                                Button(String(localized: "settings.browser.history.clearButton", defaultValue: "Clear History…")) {
                                    showClearBrowserHistoryConfirmation = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(browserHistoryEntryCount == 0)
                            }
                        }

                        SettingsSectionHeader(title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"))
                            .id(SettingsNavigationTarget.keyboardShortcuts)
                            .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
                        SettingsCard {
                            SettingsCardRow(
                                String(localized: "settings.shortcuts.showHints", defaultValue: "Show Cmd/Ctrl-Hold Shortcut Hints"),
                                subtitle: showShortcutHintsOnCommandHold
                                    ? String(localized: "settings.shortcuts.showHints.subtitleOn", defaultValue: "Holding Cmd (sidebar/titlebar) or Ctrl/Cmd (pane tabs) shows shortcut hint pills.")
                                    : String(localized: "settings.shortcuts.showHints.subtitleOff", defaultValue: "Holding Cmd or Ctrl keeps shortcut hint pills hidden.")
                            ) {
                                Toggle("", isOn: $showShortcutHintsOnCommandHold)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }

                            SettingsCardDivider()

                            let actions = KeyboardShortcutSettings.Action.allCases
                            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                ShortcutSettingRow(action: action)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                if index < actions.count - 1 {
                                    SettingsCardDivider()
                                }
                            }
                        }
                        .id(shortcutResetToken)

                        Text(String(localized: "settings.shortcuts.recordHint", defaultValue: "Click a shortcut value to record a new shortcut."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 2)
                            .accessibilityIdentifier("ShortcutRecordingHint")

                        SettingsSectionHeader(title: String(localized: "settings.section.reset", defaultValue: "Reset"))
                        SettingsCard {
                            HStack {
                                Spacer(minLength: 0)
                                Button(String(localized: "settings.reset.resetAll", defaultValue: "Reset All Settings")) {
                                    resetAllSettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .padding(.top, contentTopInset)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SettingsTopOffsetPreferenceKey.self,
                                value: proxy.frame(in: .named("SettingsScrollArea")).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "SettingsScrollArea")
                .onPreferenceChange(SettingsTopOffsetPreferenceKey.self) { value in
                    if topBlurBaselineOffset == nil {
                        topBlurBaselineOffset = value
                    }
                    topBlurOpacity = blurOpacity(forContentOffset: value)
                }

                ZStack(alignment: .top) {
                    SettingsTitleLeadingInsetReader(inset: $settingsTitleLeadingInset)
                        .frame(width: 0, height: 0)

                    AboutVisualEffectBackground(material: .underWindowBackground, blendingMode: .withinWindow)
                        .mask(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.9),
                                    Color.black.opacity(0.64),
                                    Color.black.opacity(0.36),
                                    Color.clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(0.52)

                    AboutVisualEffectBackground(material: .underWindowBackground, blendingMode: .withinWindow)
                        .mask(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.98),
                                    Color.black.opacity(0.78),
                                    Color.black.opacity(0.42),
                                    Color.clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(0.14 + (topBlurOpacity * 0.86))

                    HStack {
                        Text(String(localized: "settings.title", defaultValue: "Settings"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.92))
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, settingsTitleLeadingInset)
                    .padding(.top, 12)
                }
                .frame(height: 62)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
                .overlay(
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.07))
                        .frame(height: 1),
                    alignment: .bottom
                )
                .allowsHitTesting(false)
            }
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            .toggleStyle(.switch)
            .onAppear {
                BrowserHistoryStore.shared.loadIfNeeded()
                notificationStore.refreshAuthorizationStatus()
                browserThemeMode = BrowserThemeSettings.mode(defaults: .standard).rawValue
                browserHistoryEntryCount = BrowserHistoryStore.shared.entries.count
                browserInsecureHTTPAllowlistDraft = browserInsecureHTTPAllowlist
                reloadWorkspaceTabColorSettings()
                refreshNotificationCustomSoundStatus()
            }
            .onChange(of: notificationSound) { _, _ in
                refreshNotificationCustomSoundStatus()
            }
            .onChange(of: notificationSoundCustomFilePath) { _, _ in
                refreshNotificationCustomSoundStatus()
            }
            .onChange(of: browserInsecureHTTPAllowlist) { oldValue, newValue in
                // Keep draft in sync with external changes unless the user has local unsaved edits.
                if browserInsecureHTTPAllowlistDraft == oldValue {
                    browserInsecureHTTPAllowlistDraft = newValue
                }
            }
            .onReceive(BrowserHistoryStore.shared.$entries) { entries in
                browserHistoryEntryCount = entries.count
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                reloadWorkspaceTabColorSettings()
            }
            .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notificationName)) { notification in
                guard let target = SettingsNavigationRequest.target(from: notification) else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
            .confirmationDialog(
                String(localized: "settings.browser.history.clearDialog.title", defaultValue: "Clear browser history?"),
                isPresented: $showClearBrowserHistoryConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "settings.browser.history.clearDialog.confirm", defaultValue: "Clear History"), role: .destructive) {
                    BrowserHistoryStore.shared.clearHistory()
                }
                Button(String(localized: "settings.browser.history.clearDialog.cancel", defaultValue: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "settings.browser.history.clearDialog.message", defaultValue: "This removes visited-page suggestions from the browser omnibar."))
            }
            .confirmationDialog(
                String(localized: "settings.automation.openAccess.dialog.title", defaultValue: "Enable full open access?"),
                isPresented: $showOpenAccessConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "settings.automation.openAccess.dialog.confirm", defaultValue: "Enable Full Open Access"), role: .destructive) {
                    socketControlMode = (pendingOpenAccessMode ?? .allowAll).rawValue
                    pendingOpenAccessMode = nil
                }
                Button(String(localized: "settings.automation.openAccess.dialog.cancel", defaultValue: "Cancel"), role: .cancel) {
                    pendingOpenAccessMode = nil
                }
            } message: {
                Text(String(localized: "settings.automation.openAccess.dialog.message", defaultValue: "This disables ancestry and password checks and opens the socket to all local users. Only enable when you understand the risk."))
            }
            .confirmationDialog(
                String(localized: "settings.app.language.restartDialog.title", defaultValue: "Restart to apply language change?"),
                isPresented: $showLanguageRestartAlert,
                titleVisibility: .visible
            ) {
                Button(String(localized: "settings.app.language.restartDialog.confirm", defaultValue: "Restart Now")) {
                    relaunchApp()
                }
                Button(String(localized: "settings.app.language.restartDialog.later", defaultValue: "Later"), role: .cancel) {}
            }
            .alert(
                String(
                    localized: "settings.notifications.sound.custom.error.title",
                    defaultValue: "Custom Notification Sound Error"
                ),
                isPresented: $showNotificationCustomSoundErrorAlert
            ) {
                Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) {}
            } message: {
                Text(notificationCustomSoundErrorAlertMessage)
            }
        }
    }

    // MARK: Functions

    private func blurOpacity(forContentOffset offset: CGFloat) -> Double {
        guard let baseline = topBlurBaselineOffset else { return 0 }
        let reveal = (baseline - offset) / 24
        return Double(min(max(reveal, 0), 1))
    }

    private func previewNotificationSound() {
        if notificationSound == NotificationSoundSettings.customFileValue {
            NotificationSoundSettings.playCustomFileSound(path: notificationSoundCustomFilePath)
            return
        }
        NotificationSoundSettings.previewSound(value: notificationSound)
    }

    private func notificationCustomSoundIssueMessage(_ issue: NotificationSoundSettings.CustomSoundPreparationIssue) -> String {
        switch issue {
            case .emptyPath:
                return String(
                    localized: "settings.notifications.sound.custom.status.empty",
                    defaultValue: "Choose a custom audio file first."
                )

            case let .missingFile(path):
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                return String(
                    localized: "settings.notifications.sound.custom.status.missingFilePrefix",
                    defaultValue: "File not found: "
                ) + fileName

            case let .missingFileExtension(path):
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                return String(
                    localized: "settings.notifications.sound.custom.status.missingExtensionPrefix",
                    defaultValue: "File needs an extension: "
                ) + fileName

            case let .stagingFailed(_, details):
                let prefix = String(
                    localized: "settings.notifications.sound.custom.status.prepareFailed",
                    defaultValue: "Could not prepare this file for notifications. Try WAV, AIFF, or CAF."
                )
                return "\(prefix) (\(details))"
        }
    }

    private func notificationCustomSoundReadyStatusMessage(for path: String) -> String {
        let sourceExtension = URL(fileURLWithPath: path)
            .pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stagedExtension = NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: sourceExtension)
        if !sourceExtension.isEmpty, stagedExtension != sourceExtension {
            return String(
                localized: "settings.notifications.sound.custom.status.readyConverted",
                defaultValue: "Prepared for notifications (converted to CAF)."
            )
        }
        return String(
            localized: "settings.notifications.sound.custom.status.ready",
            defaultValue: "Ready for notifications."
        )
    }

    private func refreshNotificationCustomSoundStatus(showAlertOnFailure: Bool = false) {
        guard notificationSound == NotificationSoundSettings.customFileValue else {
            notificationCustomSoundStatusMessage = nil
            notificationCustomSoundStatusIsError = false
            return
        }
        let pathSnapshot = notificationSoundCustomFilePath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NotificationSoundSettings.prepareCustomFileForNotifications(path: pathSnapshot)
            DispatchQueue.main.async {
                guard notificationSound == NotificationSoundSettings.customFileValue else {
                    notificationCustomSoundStatusMessage = nil
                    notificationCustomSoundStatusIsError = false
                    return
                }
                guard notificationSoundCustomFilePath == pathSnapshot else { return }
                switch result {
                    case .success:
                        notificationCustomSoundStatusMessage = notificationCustomSoundReadyStatusMessage(for: pathSnapshot)
                        notificationCustomSoundStatusIsError = false

                    case let .failure(issue):
                        let message = notificationCustomSoundIssueMessage(issue)
                        notificationCustomSoundStatusMessage = message
                        notificationCustomSoundStatusIsError = true
                        if showAlertOnFailure {
                            notificationCustomSoundErrorAlertMessage = message
                            showNotificationCustomSoundErrorAlert = true
                        }
                }
            }
        }
    }

    private func chooseNotificationSoundFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.title = String(
            localized: "settings.notifications.sound.custom.choose.title",
            defaultValue: "Choose Notification Sound"
        )
        panel.prompt = String(
            localized: "settings.notifications.sound.custom.choose.prompt",
            defaultValue: "Choose"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let selectedPath = url.path
        switch NotificationSoundSettings.prepareCustomFileForNotifications(path: selectedPath) {
            case .success:
                notificationSoundCustomFilePath = selectedPath
                notificationSound = NotificationSoundSettings.customFileValue
                notificationCustomSoundStatusMessage = notificationCustomSoundReadyStatusMessage(for: selectedPath)
                notificationCustomSoundStatusIsError = false
                previewNotificationSound()

            case let .failure(issue):
                let message = notificationCustomSoundIssueMessage(issue)
                notificationCustomSoundErrorAlertMessage = message
                showNotificationCustomSoundErrorAlert = true
                refreshNotificationCustomSoundStatus()
        }
    }

    private func handleNotificationPermissionAction() {
        let state = notificationStore.authorizationState.statusLabel
        #if DEBUG
            dlog("notification.ui enableTapped state=\(state)")
        #endif
        NSLog("notification.ui enableTapped state=%@", state)
        switch notificationStore.authorizationState {
            case .unknown, .notDetermined:
                notificationStore.requestAuthorizationFromSettings()
            case .authorized, .denied, .provisional, .ephemeral:
                notificationStore.openNotificationSettings()
        }
    }

    private func saveSocketPassword() {
        let trimmed = socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.enterFirst", defaultValue: "Enter a password first.")
            socketPasswordStatusIsError = true
            return
        }

        do {
            try SocketControlPasswordStore.savePassword(trimmed)
            socketPasswordDraft = ""
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.saved", defaultValue: "Password saved.")
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.saveFailed", defaultValue: "Failed to save password (\(error.localizedDescription)).")
            socketPasswordStatusIsError = true
        }
    }

    private func clearSocketPassword() {
        do {
            try SocketControlPasswordStore.clearPassword()
            socketPasswordDraft = ""
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.cleared", defaultValue: "Password cleared.")
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.clearFailed", defaultValue: "Failed to clear password (\(error.localizedDescription)).")
            socketPasswordStatusIsError = true
        }
    }

    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open -n -- \"$RELAUNCH_PATH\""]
        task.environment = ["RELAUNCH_PATH": bundlePath]
        do {
            try task.run()
        } catch {
            return
        }
        NSApplication.shared.terminate(nil)
    }

    private func resetAllSettings() {
        isResettingSettings = true
        appLanguage = LanguageSettings.defaultLanguage.rawValue
        LanguageSettings.apply(.system)
        if appLanguage != LanguageSettings.languageAtLaunch.rawValue {
            showLanguageRestartAlert = true
        }
        appearanceMode = AppearanceSettings.defaultMode.rawValue
        appIconMode = AppIconSettings.defaultMode.rawValue
        AppIconSettings.applyIcon(.automatic)
        socketControlMode = SocketControlSettings.defaultMode.rawValue
        claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
        sendAnonymousTelemetry = TelemetrySettings.defaultSendAnonymousTelemetry
        browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
        browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
        browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
        openTerminalLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInCmuxBrowser
        interceptTerminalOpenCommandInCmuxBrowser = BrowserLinkOpenSettings.defaultInterceptTerminalOpenCommandInCmuxBrowser
        browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
        browserExternalOpenPatterns = BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns
        browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
        browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
        notificationSound = NotificationSoundSettings.defaultValue
        notificationSoundCustomFilePath = NotificationSoundSettings.defaultCustomFilePath
        notificationCustomSoundStatusMessage = nil
        notificationCustomSoundStatusIsError = false
        showNotificationCustomSoundErrorAlert = false
        notificationCustomSoundErrorAlertMessage = ""
        notificationCustomCommand = NotificationSoundSettings.defaultCustomCommand
        notificationDockBadgeEnabled = NotificationBadgeSettings.defaultDockBadgeEnabled
        notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
        notificationPaneFlashEnabled = NotificationPaneFlashSettings.defaultEnabled
        showMenuBarExtra = MenuBarExtraSettings.defaultShowInMenuBar
        warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
        commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
        commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
        ShortcutHintDebugSettings.resetVisibilityDefaults()
        alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints
        newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
        workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
        sidebarHideAllDetails = SidebarWorkspaceDetailSettings.defaultHideAllDetails
        sidebarShowNotificationMessage = SidebarWorkspaceDetailSettings.defaultShowNotificationMessage
        sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
        sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
        sidebarShowBranchDirectory = true
        sidebarShowPullRequest = true
        openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
        showShortcutHintsOnCommandHold = ShortcutHintDebugSettings.defaultShowHintsOnCommandHold
        sidebarShowPorts = true
        sidebarShowLog = true
        sidebarShowProgress = true
        sidebarShowMetadata = true
        sidebarTintHex = SidebarTintDefaults.hex
        sidebarTintHexLight = nil
        sidebarTintHexDark = nil
        sidebarTintOpacity = SidebarTintDefaults.opacity
        showOpenAccessConfirmation = false
        pendingOpenAccessMode = nil
        socketPasswordDraft = ""
        socketPasswordStatusMessage = nil
        socketPasswordStatusIsError = false
        KeyboardShortcutSettings.resetAll()
        WorkspaceTabColorSettings.reset()
        reloadWorkspaceTabColorSettings()
        shortcutResetToken = UUID()
        DispatchQueue.main.async { isResettingSettings = false }
    }

    private func defaultTabColorBinding(for name: String) -> Binding<Color> {
        Binding(
            get: {
                let hex = WorkspaceTabColorSettings.defaultColorHex(named: name)
                return Color(nsColor: NSColor(hex: hex) ?? .systemBlue)
            },
            set: { newValue in
                let hex = NSColor(newValue).hexString()
                WorkspaceTabColorSettings.setDefaultColor(named: name, hex: hex)
                reloadWorkspaceTabColorSettings()
            }
        )
    }

    private func baseTabColorHex(for name: String) -> String {
        WorkspaceTabColorSettings.defaultPalette
            .first(where: { $0.name == name })?
            .hex ?? "#1565C0"
    }

    private func removeWorkspaceCustomColor(_ hex: String) {
        WorkspaceTabColorSettings.removeCustomColor(hex)
        reloadWorkspaceTabColorSettings()
    }

    private func resetWorkspaceTabColors() {
        WorkspaceTabColorSettings.reset()
        reloadWorkspaceTabColorSettings()
    }

    private func reloadWorkspaceTabColorSettings() {
        workspaceTabDefaultEntries = WorkspaceTabColorSettings.defaultPaletteWithOverrides()
        workspaceTabCustomColors = WorkspaceTabColorSettings.customColors()
    }

    private func saveBrowserInsecureHTTPAllowlist() {
        browserInsecureHTTPAllowlist = browserInsecureHTTPAllowlistDraft
    }
}
