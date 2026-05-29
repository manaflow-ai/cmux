import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct SettingsView: View {
    private let pickerColumnWidth: CGFloat = 196
    private let notificationSoundControlWidth: CGFloat = 280
    private let shortcutChordsDocsURL = URL(string: "https://cmux.com/docs/keyboard-shortcuts#shortcut-chords")!
    private let settingsJSONDocsURL = URL(string: "https://cmux.com/docs/configuration#cmux-json")!
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("selectedSettingsSection") private var selectedSettingsSectionRaw = SettingsNavigationTarget.account.rawValue
    @State private var highlightedSearchAnchorID: String?
    @State private var searchHighlightToken = 0
    @State private var searchHighlightStartedAt: Date?
    @State private var settingsNavigationGeneration = 0

    @AppStorage(LanguageSettings.languageKey) private var appLanguage = LanguageSettings.defaultLanguage.rawValue
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage(AppIconSettings.modeKey) private var appIconMode = AppIconSettings.defaultMode.rawValue
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(ClaudeCodeIntegrationSettings.hooksEnabledKey)
    private var claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
    @AppStorage(ClaudeCodeIntegrationSettings.customClaudePathKey)
    private var customClaudePath = ""
    @AppStorage(RipgrepIntegrationSettings.customRipgrepPathKey)
    private var customRipgrepPath = ""
    @AppStorage(AgentSubagentNotificationSettings.suppressNotificationsKey)
    private var suppressSubagentNotifications = AgentSubagentNotificationSettings.defaultSuppressNotifications
    @AppStorage(CursorIntegrationSettings.hooksEnabledKey)
    private var cursorHooksEnabled = CursorIntegrationSettings.defaultHooksEnabled
    @AppStorage(GeminiIntegrationSettings.hooksEnabledKey)
    private var geminiHooksEnabled = GeminiIntegrationSettings.defaultHooksEnabled
    @AppStorage(TelemetrySettings.sendAnonymousTelemetryKey)
    private var sendAnonymousTelemetry = TelemetrySettings.defaultSendAnonymousTelemetry
    @AppStorage(PreferredEditorSettings.key) private var preferredEditorCommand = ""
    @AppStorage(CmdClickSupportedFileRouteSettings.key)
    private var openSupportedFilesInCmux = CmdClickSupportedFileRouteSettings.defaultValue
    @AppStorage(CmdClickMarkdownRouteSettings.key) private var openMarkdownInCmuxViewer = CmdClickMarkdownRouteSettings.defaultValue
    @AppStorage(AutomationSettings.portBaseKey) private var cmuxPortBase = AutomationSettings.defaultPortBase
    @AppStorage(AutomationSettings.portRangeKey) private var cmuxPortRange = AutomationSettings.defaultPortRange
    @AppStorage(BrowserSearchSettings.searchEngineKey) private var browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
    @AppStorage(BrowserSearchSettings.customSearchEngineNameKey) private var browserCustomSearchEngineName = BrowserSearchSettings.defaultCustomSearchEngineName
    @AppStorage(BrowserSearchSettings.customSearchEngineURLTemplateKey) private var browserCustomSearchEngineURLTemplate = BrowserSearchSettings.defaultCustomSearchEngineURLTemplate
    @AppStorage(BrowserSearchSettings.searchSuggestionsEnabledKey) private var browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
    @AppStorage(BrowserThemeSettings.modeKey) private var browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
    @AppStorage(BrowserAvailabilitySettings.disabledKey) private var browserDisabled = BrowserAvailabilitySettings.defaultDisabled
    @AppStorage(BrowserHiddenWebViewDiscardPolicy.enabledKey)
    private var browserHiddenWebViewDiscardEnabled = BrowserHiddenWebViewDiscardPolicy.defaultEnabled
    @AppStorage(BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
    private var browserHiddenWebViewDiscardDelay = BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay
    @AppStorage(BrowserImportHintSettings.variantKey) private var browserImportHintVariantRaw = BrowserImportHintSettings.defaultVariant.rawValue
    @AppStorage(BrowserImportHintSettings.showOnBlankTabsKey) private var showBrowserImportHintOnBlankTabs = BrowserImportHintSettings.defaultShowOnBlankTabs
    @AppStorage(BrowserImportHintSettings.dismissedKey) private var isBrowserImportHintDismissed = BrowserImportHintSettings.defaultDismissed
    @AppStorage(ReactGrabSettings.versionKey) private var reactGrabVersion = ReactGrabSettings.defaultVersion
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
    @AppStorage(MenuBarOnlySettings.menuBarOnlyKey) private var menuBarOnly = MenuBarOnlySettings.defaultMenuBarOnly
    @AppStorage(QuitWarningSettings.confirmQuitKey)
    private var confirmQuitModeRaw = QuitWarningSettings.defaultConfirmQuitMode.rawValue
    @AppStorage(QuitWarningSettings.warnBeforeQuitKey) private var warnBeforeQuitShortcut = QuitWarningSettings.defaultWarnBeforeQuit
    @AppStorage(CloseTabWarningSettings.warnBeforeClosingTabKey) private var warnBeforeClosingTab = CloseTabWarningSettings.defaultWarnBeforeClosingTab
    @AppStorage(CloseTabWarningSettings.warnBeforeClosingTabXButtonKey)
    private var warnBeforeClosingTabXButton = CloseTabWarningSettings.defaultWarnBeforeClosingTabXButton
    @AppStorage(CloseTabWarningSettings.hideTabCloseButtonKey)
    private var hideTabCloseButton = CloseTabWarningSettings.defaultHideTabCloseButton
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    private var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @AppStorage(WorkspacePlacementSettings.placementKey) private var newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
    @AppStorage(WorkspaceWorkingDirectoryInheritanceSettings.key)
    private var workspaceInheritWorkingDirectory = WorkspaceWorkingDirectoryInheritanceSettings.defaultValue
    @AppStorage(LastSurfaceCloseShortcutSettings.key)
    private var closeWorkspaceOnLastSurfaceShortcut = LastSurfaceCloseShortcutSettings.defaultValue
    @AppStorage(PaneFirstClickFocusSettings.enabledKey)
    private var paneFirstClickFocusEnabled = PaneFirstClickFocusSettings.defaultEnabled
    @AppStorage(TerminalScrollBarSettings.showScrollBarKey)
    private var showTerminalScrollBar = TerminalScrollBarSettings.defaultShowScrollBar
    @AppStorage(TerminalTextBoxInputSettings.maxLinesKey)
    private var textBoxMaxLines = TerminalTextBoxInputSettings.defaultMaxLines
    @AppStorage(TerminalCopyOnSelectSettings.copyOnSelectKey)
    private var terminalCopyOnSelect = TerminalCopyOnSelectSettings.defaultCopyOnSelect
    @AppStorage(FileDropBehaviorSettings.defaultBehaviorKey)
    private var fileDropDefaultBehavior = FileDropBehaviorSettings.defaultBehavior.rawValue
    @AppStorage(AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
    private var autoResumeAgentSessions = AgentSessionAutoResumeSettings.defaultAutoResumeAgentSessions
    @AppStorage(AgentHibernationSettings.enabledKey)
    private var agentHibernationEnabled = AgentHibernationSettings.defaultEnabled
    @AppStorage(AgentHibernationSettings.idleSecondsKey)
    private var agentHibernationIdleSeconds = AgentHibernationSettings.defaultIdleSeconds
    @AppStorage(AgentHibernationSettings.maxLiveTerminalsKey)
    private var agentHibernationMaxLiveTerminals = AgentHibernationSettings.defaultMaxLiveTerminals
    @AppStorage(WorkspaceAutoReorderSettings.key) private var workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
    @AppStorage(IMessageModeSettings.key) private var iMessageMode = IMessageModeSettings.defaultValue
    @AppStorage(SidebarWorkspaceDetailSettings.hideAllDetailsKey)
    private var sidebarHideAllDetails = SidebarWorkspaceDetailSettings.defaultHideAllDetails
    @AppStorage(SidebarWorkspaceDetailSettings.showWorkspaceDescriptionKey)
    private var sidebarShowWorkspaceDescription = SidebarWorkspaceDetailSettings.defaultShowWorkspaceDescription
    @AppStorage(SidebarWorkspaceTitleWrapSettings.key)
    private var sidebarWrapWorkspaceTitles = SidebarWorkspaceTitleWrapSettings.defaultWrap
    @AppStorage(SidebarWorkspaceDetailSettings.showNotificationMessageKey)
    private var sidebarShowNotificationMessage = SidebarWorkspaceDetailSettings.defaultShowNotificationMessage
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage(SidebarBranchDirectoryStackedSettings.key) private var sidebarBranchDirectoryStacked = SidebarBranchDirectoryStackedSettings.defaultStacked
    @AppStorage(SidebarPathLastSegmentSettings.key) private var sidebarPathLastSegmentOnly = SidebarPathLastSegmentSettings.defaultLastSegmentOnly
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage("sidebarSelectionColorHex") private var sidebarSelectionColorHex: String?
    @AppStorage("sidebarNotificationBadgeColorHex") private var sidebarNotificationBadgeColorHex: String?
    @AppStorage("sidebarShowBranchDirectory") private var sidebarShowBranchDirectory = SidebarWorkspaceDetailDefaults.showBranchDirectory
    @AppStorage("sidebarShowPullRequest") private var sidebarShowPullRequest = SidebarWorkspaceDetailDefaults.showPullRequests
    @AppStorage(SidebarWorkspaceDetailDefaults.watchGitStatusKey) private var sidebarWatchGitStatus = SidebarWorkspaceDetailDefaults.watchGitStatus
    @AppStorage(SidebarPullRequestClickabilitySettings.key) private var sidebarMakePullRequestClickable = SidebarPullRequestClickabilitySettings.defaultClickable
    @AppStorage(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
    private var openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
    @AppStorage(BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey)
    private var openSidebarPortLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPortLinksInCmuxBrowser
    @AppStorage("sidebarShowSSH") private var sidebarShowSSH = SidebarWorkspaceDetailDefaults.showSSH
    @AppStorage("sidebarShowPorts") private var sidebarShowPorts = SidebarWorkspaceDetailDefaults.showPorts
    @AppStorage("sidebarShowLog") private var sidebarShowLog = SidebarWorkspaceDetailDefaults.showLog
    @AppStorage("sidebarShowProgress") private var sidebarShowProgress = SidebarWorkspaceDetailDefaults.showProgress
    @AppStorage("sidebarShowStatusPills") private var sidebarShowMetadata = SidebarWorkspaceDetailDefaults.showCustomMetadata
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarMatchTerminalBackground") private var sidebarMatchTerminalBackground = false
    @AppStorage(RightSidebarBetaFeatureSettings.dockEnabledKey)
    private var rightSidebarDockEnabled = RightSidebarBetaFeatureSettings.defaultDockEnabled

    @ObservedObject private var notificationStore = TerminalNotificationStore.shared
    @ObservedObject private var authManager = AuthManager.shared
    @StateObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var shortcutResetToken = UUID()
    @State private var showClearBrowserHistoryConfirmation = false
    @State private var showOpenAccessConfirmation = false
    @State private var pendingOpenAccessMode: SocketControlMode?
    @State private var browserHistoryEntryCount: Int = 0
    @State private var didLoadBrowserHistoryForSettings = false
    @State private var detectedImportBrowsers: [InstalledBrowserCandidate] = []
    @State private var didRequestBrowserImportDetection = false
    @State private var isDetectingImportBrowsers = false
    @State private var browserImportDetectionGeneration = 0
    @Bindable var draftState: SettingsDraftState
    @State private var socketPasswordStatusMessage: String?
    @State private var socketPasswordStatusIsError = false
    @State private var notificationCustomSoundStatusMessage: String?
    @State private var notificationCustomSoundStatusIsError = false
    @State private var showNotificationCustomSoundErrorAlert = false
    @State private var notificationCustomSoundErrorAlertMessage = ""
    @State private var telemetryValueAtLaunch = TelemetrySettings.enabledForCurrentLaunch
    @State private var showLanguageRestartAlert = false
    @State private var isResettingSettings = false
    @State private var workspaceTabPaletteEntries = WorkspaceTabColorSettings.palette()

    private var selectedWorkspacePlacement: NewWorkspacePlacement {
        NewWorkspacePlacement(rawValue: newWorkspacePlacement) ?? WorkspacePlacementSettings.defaultPlacement
    }

    private var workspaceWorkingDirectoryInheritanceSubtitle: String {
        if workspaceInheritWorkingDirectory {
            return String(
                localized: "settings.app.workspaceInheritWorkingDirectory.subtitleOn",
                defaultValue: "New workspaces start in the focused workspace's working directory."
            )
        }
        return String(
            localized: "settings.app.workspaceInheritWorkingDirectory.subtitleOff",
            defaultValue: "New workspaces leave their working directory unset so Ghostty's working-directory setting can apply."
        )
    }

    private var minimalModeEnabled: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var minimalModeSubtitle: String {
        if minimalModeEnabled {
            return String(
                localized: "settings.app.minimalMode.subtitleOn",
                defaultValue: "Hide the workspace title bar and move workspace controls into the sidebar."
            )
        }
        return String(
            localized: "settings.app.minimalMode.subtitleOff",
            defaultValue: "Use the standard workspace title bar and controls."
        )
    }

    private var keepWorkspaceOpenOnLastSurfaceShortcut: Bool {
        !closeWorkspaceOnLastSurfaceShortcut
    }

    private var keepWorkspaceOpenOnLastSurfaceShortcutBinding: Binding<Bool> {
        Binding(
            get: { keepWorkspaceOpenOnLastSurfaceShortcut },
            set: { closeWorkspaceOnLastSurfaceShortcut = !$0 }
        )
    }

    private var closeWorkspaceOnLastSurfaceShortcutSubtitle: String {
        if keepWorkspaceOpenOnLastSurfaceShortcut {
            return String(
                localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut.subtitleOn",
                defaultValue: "When the focused surface is the last one in its workspace, the close-surface shortcut closes only the surface and keeps the workspace open. Use the close-workspace shortcut to close the workspace explicitly."
            )
        }
        return String(
            localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut.subtitleOff",
            defaultValue: "When the focused surface is the last one in its workspace, the close-surface shortcut also closes the workspace."
        )
    }

    private var paneFirstClickFocusSubtitle: String {
        if paneFirstClickFocusEnabled {
            return String(
                localized: "settings.app.paneFirstClickFocus.subtitleOn",
                defaultValue: "When cmux is inactive, clicking a pane activates the window and focuses that pane in one click."
            )
        }
        return String(
            localized: "settings.app.paneFirstClickFocus.subtitleOff",
            defaultValue: "When cmux is inactive, the first click only activates the window. Click again to focus the pane."
        )
    }

    private var confirmQuitModeBinding: Binding<QuitConfirmationMode> {
        Binding(
            get: { QuitWarningSettings.confirmQuitMode() },
            set: { mode in
                QuitWarningSettings.setMode(mode)
                confirmQuitModeRaw = mode.rawValue
                warnBeforeQuitShortcut = mode != .never
            }
        )
    }

    private var confirmQuitModeForSettingsDisplay: QuitConfirmationMode {
        _ = confirmQuitModeRaw
        _ = warnBeforeQuitShortcut
        return QuitWarningSettings.confirmQuitMode()
    }

    private var confirmQuitDevOverrideActive: Bool {
        BuildFlavor.current == .dev
    }

    private var confirmQuitModeSubtitle: String {
        if confirmQuitDevOverrideActive {
            return String(
                localized: "settings.app.confirmQuit.subtitleDevOverride",
                defaultValue: "DEV build: quit confirmations are disabled."
            )
        }

        switch confirmQuitModeForSettingsDisplay {
        case .always:
            return String(
                localized: "settings.app.warnBeforeQuit.subtitleOn",
                defaultValue: "Show a confirmation before quitting with Cmd+Q."
            )
        case .dirtyOnly:
            return String(
                localized: "settings.app.confirmQuit.subtitleDirtyOnly",
                defaultValue: "Show a confirmation only when a workspace needs close confirmation."
            )
        case .never:
            return String(
                localized: "settings.app.warnBeforeQuit.subtitleOff",
                defaultValue: "Cmd+Q quits immediately without confirmation."
            )
        }
    }

    private var warnBeforeClosingTabXButtonSubtitle: String {
        if hideTabCloseButton {
            return String(
                localized: "settings.app.warnBeforeClosingTabXButton.subtitleHidden",
                defaultValue: "Tab close buttons are hidden, so this warning is inactive."
            )
        }
        if warnBeforeClosingTabXButton {
            return String(
                localized: "settings.app.warnBeforeClosingTabXButton.subtitleOn",
                defaultValue: "The tab close button asks for confirmation before closing."
            )
        }
        return String(
            localized: "settings.app.warnBeforeClosingTabXButton.subtitleOff",
            defaultValue: "The tab close button closes tabs immediately."
        )
    }

    private var showTerminalScrollBarBinding: Binding<Bool> {
        Binding(
            get: { showTerminalScrollBar },
            set: { newValue in
                guard showTerminalScrollBar != newValue else { return }
                showTerminalScrollBar = newValue
                TerminalScrollBarSettings.notifyDidChange()
            }
        )
    }

    private var terminalCopyOnSelectBinding: Binding<Bool> {
        Binding(
            get: { terminalCopyOnSelect },
            set: { newValue in
                guard terminalCopyOnSelect != newValue else { return }
                terminalCopyOnSelect = newValue
                TerminalCopyOnSelectSettings.notifyDidChange()
            }
        )
    }

    private var selectedFileDropDefaultBehavior: FileDropDefaultBehavior {
        FileDropBehaviorSettings.behavior(for: fileDropDefaultBehavior)
    }

    private var resolvedTextBoxMaxLines: Int {
        TerminalTextBoxInputSettings.resolvedMaxLines(textBoxMaxLines)
    }

    private var textBoxMaxLinesBinding: Binding<Int> {
        Binding(
            get: { resolvedTextBoxMaxLines },
            set: { textBoxMaxLines = TerminalTextBoxInputSettings.resolvedMaxLines($0) }
        )
    }

    private var fileDropDefaultBehaviorSelection: Binding<String> {
        Binding(
            get: { selectedFileDropDefaultBehavior.rawValue },
            set: { newValue in
                fileDropDefaultBehavior = FileDropBehaviorSettings.behavior(for: newValue).rawValue
            }
        )
    }

    private var autoResumeAgentSessionsBinding: Binding<Bool> {
        Binding(
            get: { autoResumeAgentSessions },
            set: { newValue in
                guard autoResumeAgentSessions != newValue else { return }
                autoResumeAgentSessions = newValue
                AgentSessionAutoResumeSettings.notifyDidChange()
            }
        )
    }

    private var agentHibernationEnabledBinding: Binding<Bool> {
        Binding(
            get: { agentHibernationEnabled },
            set: { newValue in
                AgentHibernationSettings.setValues(enabled: newValue)
                agentHibernationEnabled = newValue
            }
        )
    }

    private var agentHibernationIdleSecondsBinding: Binding<Double> {
        Binding(
            get: { AgentHibernationSettings.sanitizedIdleSeconds(agentHibernationIdleSeconds) },
            set: { newValue in
                let sanitized = AgentHibernationSettings.sanitizedIdleSeconds(newValue)
                AgentHibernationSettings.setValues(idleSeconds: sanitized)
                agentHibernationIdleSeconds = sanitized
            }
        )
    }

    private var agentHibernationMaxLiveTerminalsBinding: Binding<Int> {
        Binding(
            get: { AgentHibernationSettings.sanitizedMaxLiveTerminals(agentHibernationMaxLiveTerminals) },
            set: { newValue in
                let sanitized = AgentHibernationSettings.sanitizedMaxLiveTerminals(newValue)
                AgentHibernationSettings.setValues(maxLiveTerminals: sanitized)
                agentHibernationMaxLiveTerminals = sanitized
            }
        )
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

    private var selectionColorBinding: Binding<Color> {
        Binding(
            get: {
                if let hex = sidebarSelectionColorHex, let nsColor = NSColor(hex: hex) {
                    return Color(nsColor: nsColor)
                }
                return cmuxAccentColor()
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarSelectionColorHex = nsColor.hexString()
            }
        )
    }

    private var notificationBadgeColorBinding: Binding<Color> {
        Binding(
            get: {
                if let hex = sidebarNotificationBadgeColorHex, let nsColor = NSColor(hex: hex) {
                    return Color(nsColor: nsColor)
                }
                return cmuxAccentColor()
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarNotificationBadgeColorHex = nsColor.hexString()
            }
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

    private var browserEnabledBinding: Binding<Bool> {
        Binding(
            get: { !browserDisabled },
            set: { newValue in
                BrowserAvailabilitySettings.setDisabled(!newValue)
                browserDisabled = !newValue
            }
        )
    }

    private var supportedFileRoutingBinding: Binding<Bool> {
        Binding(
            get: { openSupportedFilesInCmux },
            set: { newValue in
                CmdClickSupportedFileRouteSettings.setEnabled(newValue)
                openSupportedFilesInCmux = newValue
            }
        )
    }

    private var markdownRoutingBinding: Binding<Bool> {
        Binding(
            get: { openMarkdownInCmuxViewer },
            set: { newValue in
                CmdClickMarkdownRouteSettings.setEnabled(newValue)
                openMarkdownInCmuxViewer = newValue
            }
        )
    }

    private var browserEnabledSubtitle: String {
        if browserDisabled {
            return String(localized: "settings.browser.enabled.subtitleOff", defaultValue: "Browser tabs and link interception are disabled. Links open in your default browser.")
        }
        return String(localized: "settings.browser.enabled.subtitleOn", defaultValue: "Browser tabs, terminal link clicks, and intercepted open commands can use the embedded browser.")
    }

    private var browserHiddenWebViewDiscardDelayBinding: Binding<Double> {
        Binding(
            get: { BrowserHiddenWebViewDiscardPolicy.clampedHiddenDelay(browserHiddenWebViewDiscardDelay) },
            set: { browserHiddenWebViewDiscardDelay = BrowserHiddenWebViewDiscardPolicy.clampedHiddenDelay($0) }
        )
    }

    private var browserHiddenWebViewDiscardSubtitle: String {
        if browserHiddenWebViewDiscardEnabled {
            return String(localized: "settings.browser.hiddenWebViewDiscard.subtitleOn", defaultValue: "Hidden browser tabs release page memory after the delay below, then restore when shown again.")
        }
        return String(localized: "settings.browser.hiddenWebViewDiscard.subtitleOff", defaultValue: "Hidden browser tabs keep page memory until closed.")
    }

    private var browserHiddenWebViewDiscardDelaySubtitle: String {
        String(localized: "settings.browser.hiddenWebViewDiscardDelay.subtitle", defaultValue: "How long a browser tab must stay hidden before cmux frees its page memory. Active downloads, popups, developer tools, fullscreen, and loading pages are skipped.")
    }

    private var browserHiddenWebViewDiscardDelayLabel: String {
        let seconds = Int(BrowserHiddenWebViewDiscardPolicy.clampedHiddenDelay(browserHiddenWebViewDiscardDelay).rounded())
        if seconds < 60 {
            let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.seconds", defaultValue: "%llds")
            return String.localizedStringWithFormat(format, Int64(seconds))
        }
        if seconds % 60 == 0 {
            let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.minutes", defaultValue: "%lldm")
            return String.localizedStringWithFormat(format, Int64(seconds / 60))
        }
        let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.minutesSeconds", defaultValue: "%lldm %llds")
        return String.localizedStringWithFormat(format, Int64(seconds / 60), Int64(seconds % 60))
    }

    @ViewBuilder
    private var browserEnabledSettingsRows: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.browser.enabled", defaultValue: "Enable cmux Browser"),
            subtitle: browserEnabledSubtitle,
            searchAnchorID: SettingsSearchIndex.settingID(for: .browser, idSuffix: "enable-browser")
        ) {
            Toggle("", isOn: browserEnabledBinding)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("BrowserEnabledToggle")
        }

        SettingsCardDivider()
    }

    private var browserImportHintVariant: BrowserImportHintVariant {
        BrowserImportHintSettings.variant(for: browserImportHintVariantRaw)
    }

    private var browserImportHintPresentation: BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: browserImportHintVariant,
            showOnBlankTabs: showBrowserImportHintOnBlankTabs,
            isDismissed: isBrowserImportHintDismissed
        )
    }

    private var browserImportHintVisibilityBinding: Binding<Bool> {
        Binding(
            get: { showBrowserImportHintOnBlankTabs },
            set: { newValue in
                showBrowserImportHintOnBlankTabs = newValue
                if newValue {
                    isBrowserImportHintDismissed = false
                }
            }
        )
    }

    private var socketModeSelection: Binding<String> {
        Binding(
            get: { socketControlMode },
            set: { newValue in
                let normalized = SocketControlSettings.migrateMode(newValue)
                if normalized == .allowAll && selectedSocketControlMode != .allowAll {
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

    private var minimalModeBinding: Binding<Bool> {
        Binding(
            get: { minimalModeEnabled },
            set: { newValue in
                workspacePresentationMode = newValue
                    ? WorkspacePresentationModeSettings.Mode.minimal.rawValue
                    : WorkspacePresentationModeSettings.Mode.standard.rawValue
            }
        )
    }

    private var menuBarOnlyBinding: Binding<Bool> {
        Binding(
            get: { menuBarOnly },
            set: { newValue in
                menuBarOnly = newValue
                SettingsWindowPresenter.refocusIfVisible()
            }
        )
    }

    private var showMenuBarExtraBinding: Binding<Bool> {
        Binding(
            get: { menuBarOnly || showMenuBarExtra },
            set: { newValue in
                guard !menuBarOnly else { return }
                showMenuBarExtra = newValue
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
        guard didLoadBrowserHistoryForSettings else {
            return String(
                localized: "settings.browser.history.subtitleLoading",
                defaultValue: "Checking browsing history..."
            )
        }

        switch browserHistoryEntryCount {
        case 0:
            return String(localized: "settings.browser.history.subtitleEmpty", defaultValue: "No saved pages yet.")
        case 1:
            return String(localized: "settings.browser.history.subtitleOne", defaultValue: "1 saved page appears in omnibar suggestions.")
        default:
            return String(localized: "settings.browser.history.subtitleMany", defaultValue: "\(browserHistoryEntryCount) saved pages appear in omnibar suggestions.")
        }
    }

    private var browserImportSubtitle: String {
        if isDetectingImportBrowsers || !didRequestBrowserImportDetection {
            return String(
                localized: "settings.browser.import.detecting",
                defaultValue: "Checking installed browsers..."
            )
        }
        return InstalledBrowserDetector.summaryText(for: detectedImportBrowsers)
    }

    private var browserImportHintSettingsNote: String {
        switch browserImportHintPresentation.settingsStatus {
        case .visible:
            return String(localized: "settings.browser.import.hint.note.visible", defaultValue: "Blank browser tabs can show this import suggestion. Hide or re-enable it here.")
        case .hidden:
            return String(localized: "settings.browser.import.hint.note.hidden", defaultValue: "The blank-tab import hint is hidden. Turn it back on here any time.")
        case .settingsOnly:
            return String(localized: "settings.browser.import.hint.note.settingsOnly", defaultValue: "Blank tabs are currently using Settings only mode from the debug window.")
        }
    }

    private var browserInsecureHTTPAllowlistHasUnsavedChanges: Bool {
        draftState.browserInsecureHTTPAllowlistDraft != browserInsecureHTTPAllowlist
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
            return false
        case NotificationSoundSettings.customFileValue:
            return hasCustomNotificationSoundFilePath
        default:
            return true
        }
    }

    private var notificationPermissionStatusText: String {
        notificationStore.authorizationState.statusLabel
    }

    private var notificationPermissionStatusColor: Color {
        switch notificationStore.authorizationState {
        case .authorized, .provisional, .ephemeral:
            return .green
        case .denied:
            return .red
        case .unknown, .notDetermined:
            return .secondary
        }
    }

    private var notificationPermissionSubtitle: String {
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            return "Desktop notifications are not enabled yet."
        case .authorized:
            return "Desktop notifications are enabled."
        case .denied:
            return "Desktop notifications are disabled in System Settings."
        case .provisional:
            return "Desktop notifications are enabled with quiet delivery."
        case .ephemeral:
            return "Desktop notifications are temporarily enabled."
        }
    }

    private var notificationPermissionActionTitle: String {
        switch notificationStore.authorizationState {
        case .unknown, .notDetermined:
            return "Enable"
        case .authorized, .denied, .provisional, .ephemeral:
            return "Open Settings"
        }
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
        case .missingFile(let path):
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return String(
                localized: "settings.notifications.sound.custom.status.missingFilePrefix",
                defaultValue: "File not found: "
            ) + fileName
        case .missingFileExtension(let path):
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return String(
                localized: "settings.notifications.sound.custom.status.missingExtensionPrefix",
                defaultValue: "File needs an extension: "
            ) + fileName
        case .stagingFailed(_, let details):
            let prefix = String(
                localized: "settings.notifications.sound.custom.status.prepareFailed",
                defaultValue: "Could not prepare this file for notifications. Try WAV, AIFF, or CAF."
            )
            return "\(prefix) (\(details))"
        }
    }

    private func notificationCustomSoundReadyStatusMessage(for path: String) -> String {
        let sourceExtension = URL(fileURLWithPath: path).pathExtension
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
                case .failure(let issue):
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

    private func applySettingsNavigation(
        _ destination: SettingsNavigationDestination,
        proxy: ScrollViewProxy
    ) {
        settingsNavigationGeneration += 1
        let navigationGeneration = settingsNavigationGeneration
        let sectionID = SettingsSearchIndex.sectionID(for: destination.target)
        prepareSettingsDestinationIfNeeded(destination)
        if destination.shouldHighlight {
            highlightedSearchAnchorID = destination.anchorID
            searchHighlightStartedAt = Date()
            searchHighlightToken += 1
        } else {
            highlightedSearchAnchorID = nil
            searchHighlightStartedAt = nil
        }
        DispatchQueue.main.async {
            guard navigationGeneration == settingsNavigationGeneration else { return }
            proxy.scrollTo(sectionID, anchor: .top)
            if destination.shouldHighlight {
                proxy.scrollTo(destination.anchorID, anchor: .center)
            }
        }
    }

    private func prepareSettingsDestinationIfNeeded(_ destination: SettingsNavigationDestination) {
        if destination.anchorID == SettingsSearchIndex.settingID(for: .browser, idSuffix: "history") {
            loadBrowserHistoryForSettingsIfNeeded()
        }

        let browserImportAnchorIDs: Set<String> = [
            SettingsSearchIndex.sectionID(for: .browserImport),
            SettingsSearchIndex.settingID(for: .browserImport, idSuffix: "import-data"),
            SettingsSearchIndex.settingID(for: .browserImport, idSuffix: "import-hint")
        ]
        if destination.target == .browserImport || browserImportAnchorIDs.contains(destination.anchorID) {
            refreshDetectedImportBrowsersIfNeeded()
        }
    }

    private func handleSettingsLazyLoadFrames(
        _ frames: [SettingsLazyLoadTrigger: CGRect],
        viewportHeight: CGFloat
    ) {
        guard viewportHeight > 0 else { return }

        for trigger in SettingsLazyLoadTrigger.allCases {
            guard let frame = frames[trigger],
                  Self.settingsLazyLoadFrameIsNearVisible(frame, viewportHeight: viewportHeight) else {
                continue
            }
            switch trigger {
            case .browserHistory:
                loadBrowserHistoryForSettingsIfNeeded()
            case .browserImport:
                refreshDetectedImportBrowsersIfNeeded()
            }
        }
    }

    private static func settingsLazyLoadFrameIsNearVisible(
        _ frame: CGRect,
        viewportHeight: CGFloat
    ) -> Bool {
        let preloadPadding: CGFloat = 160
        return frame.maxY >= -preloadPadding && frame.minY <= viewportHeight + preloadPadding
    }

    private func loadBrowserHistoryForSettingsIfNeeded() {
        guard !didLoadBrowserHistoryForSettings else { return }
        BrowserHistoryStore.shared.loadIfNeeded()
        didLoadBrowserHistoryForSettings = BrowserHistoryStore.shared.isLoaded
        guard didLoadBrowserHistoryForSettings else { return }
        browserHistoryEntryCount = BrowserHistoryStore.shared.entries.count
    }

    private func refreshDetectedImportBrowsersIfNeeded() {
        guard !didRequestBrowserImportDetection else { return }
        didRequestBrowserImportDetection = true
        refreshDetectedImportBrowsers()
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
        case .failure(let issue):
            let message = notificationCustomSoundIssueMessage(issue)
            notificationCustomSoundErrorAlertMessage = message
            showNotificationCustomSoundErrorAlert = true
            refreshNotificationCustomSoundStatus()
        }
    }

    private func handleNotificationPermissionAction() {
        let state = notificationStore.authorizationState.statusLabel
#if DEBUG
        cmuxDebugLog("notification.ui enableTapped state=\(state)")
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
        let trimmed = draftState.socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.enterFirst", defaultValue: "Enter a password first.")
            socketPasswordStatusIsError = true
            return
        }

        do {
            try SocketControlPasswordStore.savePassword(trimmed)
            draftState.socketPasswordDraft = ""
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
            draftState.socketPasswordDraft = ""
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.cleared", defaultValue: "Password cleared.")
            socketPasswordStatusIsError = false
        } catch {
            socketPasswordStatusMessage = String(localized: "settings.automation.socketPassword.clearFailed", defaultValue: "Failed to clear password (\(error.localizedDescription)).")
            socketPasswordStatusIsError = true
        }
    }

    var body: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let _ = Self.validateBypassedSettingsConfigurationReviews()
        GeometryReader { viewportProxy in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                    SettingsSectionHeader(title: String(localized: "settings.section.account", defaultValue: "Account"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .account))
                    SettingsCard {
                        AuthSettingsRow(authManager: authManager)
                    }
                    .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .account, idSuffix: "account"))

                    SettingsSectionHeader(title: String(localized: "settings.section.app", defaultValue: "App"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .app))
                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .json("app.language"),
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
                            .onChange(of: appLanguage) { newValue in
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
                            configurationReview: .json("app.appearance"),
                            selectedMode: appearanceMode,
                            onSelect: { mode in
                                let selected = AppearanceSettings.selectMode(
                                    mode,
                                    source: "settings.themePicker"
                                )
                                appearanceMode = selected.rawValue
                            }
                        )

                        SettingsCardDivider()

                        AppIconPickerRow(
                            configurationReview: .json("app.appIcon"),
                            selectedMode: appIconMode,
                            onSelect: { mode in
                                appIconMode = mode.rawValue
                                AppIconSettings.applyIcon(mode)
                            }
                        )

                        SettingsCardDivider()

                        SettingsPickerRow(
                            configurationReview: .json("app.newWorkspacePlacement"),
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
                            configurationReview: .json("app.workspaceInheritWorkingDirectory"),
                            String(
                                localized: "settings.app.workspaceInheritWorkingDirectory",
                                defaultValue: "Inherit Workspace Working Directory"
                            ),
                            subtitle: workspaceWorkingDirectoryInheritanceSubtitle
                        ) {
                            Toggle("", isOn: $workspaceInheritWorkingDirectory)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsWorkspaceInheritWorkingDirectoryToggle")
                                .accessibilityLabel(
                                    String(
                                        localized: "settings.app.workspaceInheritWorkingDirectory",
                                        defaultValue: "Inherit Workspace Working Directory"
                                    )
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.minimalMode"),
                            String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode"),
                            subtitle: minimalModeSubtitle
                        ) {
                            Toggle("", isOn: minimalModeBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsMinimalModeToggle")
                                .accessibilityLabel(
                                    String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode")
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.keepWorkspaceOpenWhenClosingLastSurface"),
                            String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut", defaultValue: "Keep Workspace Open When Closing Last Surface"),
                            subtitle: closeWorkspaceOnLastSurfaceShortcutSubtitle
                        ) {
                            Toggle("", isOn: keepWorkspaceOpenOnLastSurfaceShortcutBinding)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.focusPaneOnFirstClick"),
                            String(localized: "settings.app.paneFirstClickFocus", defaultValue: "Focus Pane on First Click"),
                            subtitle: paneFirstClickFocusSubtitle
                        ) {
                            Toggle("", isOn: $paneFirstClickFocusEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityLabel(
                                    String(localized: "settings.app.paneFirstClickFocus", defaultValue: "Focus Pane on First Click")
                                )
                        }

                        SettingsCardDivider()

                        SettingsPickerRow(
                            configurationReview: .settingsOnly,
                            String(localized: "settings.app.fileDrop.defaultBehavior", defaultValue: "File Drops"),
                            subtitle: selectedFileDropDefaultBehavior.settingsSubtitle,
                            controlWidth: pickerColumnWidth,
                            selection: fileDropDefaultBehaviorSelection
                        ) {
                            ForEach(FileDropDefaultBehavior.allCases) { behavior in
                                Text(behavior.displayName).tag(behavior.rawValue)
                            }
                        }
                        .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .app, idSuffix: "file-drops"))

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.preferredEditor"),
                            String(localized: "settings.app.preferredEditor", defaultValue: "Open Files With"),
                            subtitle: String(localized: "settings.app.preferredEditor.subtitle", defaultValue: "Command used when Cmd-click file previews are disabled or a file is unsupported. Leave empty for system default.")
                        ) {
                            TextField(
                                String(localized: "settings.app.preferredEditor.placeholder", defaultValue: "e.g. code, zed, subl"),
                                text: $preferredEditorCommand
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.openSupportedFilesInCmux"),
                            String(localized: "settings.app.openSupportedFilesInCmux", defaultValue: "Open Supported Files in cmux"),
                            subtitle: String(localized: "settings.app.openSupportedFilesInCmux.subtitle", defaultValue: "Cmd-clicking readable files opens text, code, PDFs, images, audio, video, and Quick Look previews in cmux.")
                        ) {
                            Toggle("", isOn: supportedFileRoutingBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityLabel(
                                    String(localized: "settings.app.openSupportedFilesInCmux", defaultValue: "Open Supported Files in cmux")
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .action,
                            String(localized: "settings.app.configWindow", defaultValue: "Terminal Config"),
                            subtitle: String(
                                localized: "settings.app.configWindow.subtitle",
                                defaultValue: "Open the cmux terminal config and generated preview in one utility window."
                            ),
                            controlWidth: pickerColumnWidth,
                            searchAnchorID: SettingsSearchIndex.settingID(for: .app, idSuffix: "terminal-config")
                        ) {
                            Button {
                                openWindow(id: ConfigSettingsView.windowID)
                            } label: {
                                Text(String(localized: "settings.app.configWindow.openButton", defaultValue: "Open Config"))
                                    .font(.system(size: 13, weight: .regular))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.openMarkdownInCmuxViewer"),
                            String(localized: "settings.app.openMarkdownInCmuxViewer", defaultValue: "Open Markdown in cmux Viewer"),
                            subtitle: String(localized: "settings.app.openMarkdownInCmuxViewer.subtitle", defaultValue: "Cmd-clicking Markdown files opens the rendered cmux markdown viewer instead of the generic file preview.")
                        ) {
                            Toggle("", isOn: markdownRoutingBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityLabel(
                                    String(localized: "settings.app.openMarkdownInCmuxViewer", defaultValue: "Open Markdown in cmux Viewer")
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.iMessageMode"),
                            String(localized: "settings.app.iMessageMode", defaultValue: "iMessage Mode"),
                            subtitle: String(localized: "settings.app.iMessageMode.subtitle", defaultValue: "Move a workspace to the top and show the submitted message when you send an agent prompt.")
                        ) {
                            Toggle("", isOn: $iMessageMode)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityLabel(
                                    String(localized: "settings.app.iMessageMode", defaultValue: "iMessage Mode")
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.reorderOnNotification"),
                            String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"),
                            subtitle: String(localized: "settings.app.reorderOnNotification.subtitle", defaultValue: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions.")
                        ) {
                            Toggle("", isOn: $workspaceAutoReorder)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("notifications.dockBadge"),
                            String(localized: "settings.app.dockBadge", defaultValue: "Dock Badge"),
                            subtitle: String(localized: "settings.app.dockBadge.subtitle", defaultValue: "Show unread count on app icon (Dock and Cmd+Tab).")
                        ) {
                            Toggle("", isOn: $notificationDockBadgeEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.menuBarOnly"),
                            String(localized: "settings.app.menuBarOnly", defaultValue: "Menu Bar Only"),
                            subtitle: String(localized: "settings.app.menuBarOnly.subtitle", defaultValue: "Hide the Dock icon and Cmd+Tab entry. Use the menu bar item to show cmux.")
                        ) {
                            Toggle("", isOn: menuBarOnlyBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsMenuBarOnlyToggle")
                                .accessibilityLabel(
                                    String(localized: "settings.app.menuBarOnly", defaultValue: "Menu Bar Only")
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("notifications.showInMenuBar"),
                            String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar"),
                            subtitle: String(localized: "settings.app.showInMenuBar.subtitle", defaultValue: "Keep cmux in the menu bar for unread notifications and quick actions.")
                        ) {
                            Toggle("", isOn: showMenuBarExtraBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityLabel(
                                    String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar")
                                )
                        }
                        .disabled(menuBarOnly)

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("notifications.unreadPaneRing"),
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
                            configurationReview: .json("notifications.paneFlash"),
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
                            configurationReview: .action,
                            String(localized: "settings.notifications.desktop", defaultValue: "Desktop Notifications"),
                            subtitle: notificationPermissionSubtitle,
                            searchAnchorID: SettingsSearchIndex.settingID(for: .app, idSuffix: "desktop-notifications")
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
                            configurationReview: .json("notifications.sound", "notifications.customSoundFilePath"),
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
                            configurationReview: .json("notifications.command"),
                            String(localized: "settings.notifications.command", defaultValue: "Notification Command"),
                            subtitle: String(localized: "settings.notifications.command.subtitle", defaultValue: "Run a shell command when a notification arrives. $CMUX_NOTIFICATION_TITLE, $CMUX_NOTIFICATION_SUBTITLE, $CMUX_NOTIFICATION_BODY are set.")
                        ) {
                            TextField(String(localized: "settings.notifications.command.placeholder", defaultValue: "say \"done\""), text: $notificationCustomCommand)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.sendAnonymousTelemetry"),
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
                            configurationReview: .json("app.confirmQuit", "app.warnBeforeQuit"),
                            String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"),
                            subtitle: confirmQuitModeSubtitle,
                            controlWidth: pickerColumnWidth
                        ) {
                            Picker("", selection: confirmQuitModeBinding) {
                                ForEach(QuitConfirmationMode.allCases, id: \.self) { mode in
                                    Text(mode.localizedSettingsTitle).tag(mode)
                                }
                            }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                                .disabled(confirmQuitDevOverrideActive)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.warnBeforeClosingTab"),
                            String(localized: "settings.app.warnBeforeClosingTab", defaultValue: "Warn Before Closing Tab"),
                            subtitle: warnBeforeClosingTab
                                ? String(localized: "settings.app.warnBeforeClosingTab.subtitleOn", defaultValue: "Show a confirmation before closing a tab.")
                                : String(localized: "settings.app.warnBeforeClosingTab.subtitleOff", defaultValue: "Tabs close immediately without confirmation.")
                        ) {
                            Toggle("", isOn: $warnBeforeClosingTab)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.warnBeforeClosingTabXButton"),
                            String(
                                localized: "settings.app.warnBeforeClosingTabXButton",
                                defaultValue: "Warn Before Tab Close Button"
                            ),
                            subtitle: warnBeforeClosingTabXButtonSubtitle
                        ) {
                            Toggle("", isOn: $warnBeforeClosingTabXButton)
                                .labelsHidden()
                                .controlSize(.small)
                                .disabled(hideTabCloseButton)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.hideTabCloseButton"),
                            String(localized: "settings.app.hideTabCloseButton", defaultValue: "Hide Tab Close Button"),
                            subtitle: hideTabCloseButton
                                ? String(localized: "settings.app.hideTabCloseButton.subtitleOn", defaultValue: "Tab close buttons are hidden.")
                                : String(
                                    localized: "settings.app.hideTabCloseButton.subtitleOff",
                                    defaultValue: "Tab close buttons appear on hover and on the active tab."
                                )
                        ) {
                            Toggle("", isOn: $hideTabCloseButton)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("app.renameSelectsExistingName"),
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
                            configurationReview: .json("app.commandPaletteSearchesAllSurfaces"),
                            String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces"),
                            subtitle: commandPaletteSearchAllSurfaces
                                ? String(localized: "settings.app.commandPaletteSearchAllSurfaces.subtitleOn", defaultValue: "Cmd+P also matches panel surfaces across workspaces.")
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

                    }

                    SettingsSectionHeader(title: String(localized: "settings.section.terminal", defaultValue: "Terminal"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .terminal))
                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .json("terminal.showScrollBar"),
                            String(localized: "settings.terminal.scrollBar", defaultValue: "Show Terminal Scroll Bar"),
                            subtitle: showTerminalScrollBar
                                ? String(localized: "settings.terminal.scrollBar.subtitleOn", defaultValue: "Shows the right-edge terminal scroll bar in shell scrollback. cmux hides it automatically for alternate-screen style TUI surfaces and you can also disable it per workspace.")
                                : String(localized: "settings.terminal.scrollBar.subtitleOff", defaultValue: "Hides the right-edge terminal scroll bar everywhere. Changes apply immediately and persist across relaunches.")
                        ) {
                            Toggle("", isOn: showTerminalScrollBarBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsTerminalScrollBarToggle")
                                .accessibilityLabel(
                                    String(localized: "settings.terminal.scrollBar", defaultValue: "Show Terminal Scroll Bar")
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("terminal.textBoxMaxLines"),
                            String(localized: "settings.terminal.textBoxMaxLines", defaultValue: "TextBox Max Lines"),
                            subtitle: String(localized: "settings.terminal.textBoxMaxLines.subtitle", defaultValue: "Limits how tall the rich terminal input can grow before it scrolls."),
                            controlWidth: pickerColumnWidth
                        ) {
                            Stepper(
                                value: textBoxMaxLinesBinding,
                                in: TerminalTextBoxInputSettings.minimumMaxLines...TerminalTextBoxInputSettings.maximumMaxLines
                            ) {
                                Text(verbatim: "\(resolvedTextBoxMaxLines)")
                                    .monospacedDigit()
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("SettingsTerminalTextBoxMaxLinesStepper")
                            .accessibilityLabel(
                                String(localized: "settings.terminal.textBoxMaxLines", defaultValue: "TextBox Max Lines")
                            )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("terminal.copyOnSelect"),
                            String(localized: "settings.terminal.copyOnSelect", defaultValue: "Copy on Selection"),
                            subtitle: terminalCopyOnSelect
                                ? String(localized: "settings.terminal.copyOnSelect.subtitleOn", defaultValue: "Selected terminal text is copied to the system clipboard when the selection is committed.")
                                : String(localized: "settings.terminal.copyOnSelect.subtitleOff", defaultValue: "Terminal selections do not replace the system clipboard. Use Cmd+C to copy manually.")
                        ) {
                            Toggle("", isOn: terminalCopyOnSelectBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsTerminalCopyOnSelectToggle")
                            .accessibilityLabel(
                                String(localized: "settings.terminal.copyOnSelect", defaultValue: "Copy on Selection")
                            )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("terminal.autoResumeAgentSessions"),
                            String(localized: "settings.terminal.agentAutoResume", defaultValue: "Resume Agent Sessions on Reopen"),
                            subtitle: autoResumeAgentSessions
                                ? String(localized: "settings.terminal.agentAutoResume.subtitleOn", defaultValue: "When cmux reopens after quit, restored agent terminals automatically run their resume command.")
                                : String(localized: "settings.terminal.agentAutoResume.subtitleOff", defaultValue: "When cmux reopens after quit, restored agent terminals stay idle until you resume them manually.")
                        ) {
                            Toggle("", isOn: autoResumeAgentSessionsBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsTerminalAgentAutoResumeToggle")
                                .accessibilityLabel(
                                    String(localized: "settings.terminal.agentAutoResume", defaultValue: "Resume Agent Sessions on Reopen")
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("terminal.agentHibernation.enabled"),
                            String(localized: "settings.terminal.agentHibernation", defaultValue: "Agent Hibernation"),
                            subtitle: agentHibernationEnabled
                                ? String(localized: "settings.terminal.agentHibernation.subtitleOn", defaultValue: "Idle background agent terminals can be suspended when the live-terminal limit is exceeded.")
                                : String(localized: "settings.terminal.agentHibernation.subtitleOff", defaultValue: "Agent terminals stay live until you close them or quit cmux.")
                        ) {
                            Toggle("", isOn: agentHibernationEnabledBinding)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsTerminalAgentHibernationToggle")
                                .accessibilityLabel(
                                    String(localized: "settings.terminal.agentHibernation", defaultValue: "Agent Hibernation")
                                )
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("terminal.agentHibernation.idleSeconds"),
                            String(localized: "settings.terminal.agentHibernation.idleSeconds", defaultValue: "Hibernate After Idle Seconds"),
                            subtitle: String(localized: "settings.terminal.agentHibernation.idleSeconds.subtitle", defaultValue: "A terminal must have no output and report an idle agent lifecycle for this long before it can be suspended."),
                            controlWidth: 140
                        ) {
                            Stepper(
                                "\(Int(agentHibernationIdleSecondsBinding.wrappedValue))",
                                value: agentHibernationIdleSecondsBinding,
                                in: 5...604800,
                                step: 60
                            )
                            .accessibilityIdentifier("SettingsTerminalAgentHibernationIdleSecondsStepper")
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("terminal.agentHibernation.maxLiveTerminals"),
                            String(localized: "settings.terminal.agentHibernation.maxLiveTerminals", defaultValue: "Max Live Agent Terminals"),
                            subtitle: String(localized: "settings.terminal.agentHibernation.maxLiveTerminals.subtitle", defaultValue: "Visible terminals stay live. Extra idle background agent terminals hibernate oldest first."),
                            controlWidth: 120
                        ) {
                            Stepper(
                                "\(agentHibernationMaxLiveTerminalsBinding.wrappedValue)",
                                value: agentHibernationMaxLiveTerminalsBinding,
                                in: 1...256,
                                step: 1
                            )
                            .accessibilityIdentifier("SettingsTerminalAgentHibernationMaxLiveStepper")
                        }
                    }

                    SurfaceResumeApprovalSettingsCard()

                    SettingsSectionHeader(title: String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .sidebarAppearance))
                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .json("sidebarAppearance.matchTerminalBackground"),
                            String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"),
                            subtitle: String(localized: "settings.sidebarAppearance.matchTerminalBackground.subtitle", defaultValue: "Use the same background color and transparency as the terminal.")
                        ) {
                            Toggle("", isOn: $sidebarMatchTerminalBackground)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("sidebar.hideAllDetails"),
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

                        SettingsCardRow(
                            configurationReview: .json("sidebar.wrapWorkspaceTitles"),
                            String(localized: "settings.app.wrapWorkspaceTitles", defaultValue: "Wrap Workspace Titles in Sidebar"),
                            subtitle: sidebarWrapWorkspaceTitles
                                ? String(localized: "settings.app.wrapWorkspaceTitles.subtitleOn", defaultValue: "Long workspace titles can use as many lines as they need.")
                                : String(localized: "settings.app.wrapWorkspaceTitles.subtitleOff", defaultValue: "Workspace titles stay on one line and truncate at the end.")
                        ) {
                            Toggle("", isOn: $sidebarWrapWorkspaceTitles)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("sidebar.showWorkspaceDescription"),
                            String(localized: "settings.app.showWorkspaceDescription", defaultValue: "Show Workspace Description in Sidebar"),
                            subtitle: String(localized: "settings.app.showWorkspaceDescription.subtitle", defaultValue: "Display custom workspace descriptions below the workspace title.")
                        ) {
                            Toggle("", isOn: $sidebarShowWorkspaceDescription)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .disabled(sidebarHideAllDetails)

                        SettingsCardDivider()

                        SettingsPickerRow(
                            configurationReview: .json("sidebar.branchLayout"),
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
                            configurationReview: .json("sidebar.stackBranchDirectory"),
                            String(localized: "settings.app.stackBranchDirectory", defaultValue: "Stack Branch and Directory"),
                            subtitle: sidebarBranchDirectoryStacked
                                ? String(localized: "settings.app.stackBranchDirectory.subtitleOn", defaultValue: "Branch and directory render on separate lines.")
                                : String(localized: "settings.app.stackBranchDirectory.subtitleOff", defaultValue: "Branch and directory share a single line.")
                        ) {
                            Toggle("", isOn: $sidebarBranchDirectoryStacked)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .disabled(sidebarHideAllDetails)

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("sidebar.pathLastSegmentOnly"),
                            String(localized: "settings.app.pathLastSegmentOnly", defaultValue: "Truncate Path From Start"),
                            subtitle: sidebarPathLastSegmentOnly
                                ? String(localized: "settings.app.pathLastSegmentOnly.subtitleOn", defaultValue: "Show as much of the trailing path as fits; shorter forms are prefixed with …/.")
                                : String(localized: "settings.app.pathLastSegmentOnly.subtitleOff", defaultValue: "Render full paths abbreviated with ~/.")
                        ) {
                            Toggle("", isOn: $sidebarPathLastSegmentOnly)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .disabled(sidebarHideAllDetails)

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("sidebar.showNotificationMessage"),
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
                            configurationReview: .json("sidebar.showBranchDirectory"),
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
                            configurationReview: .json("sidebar.showPullRequests"),
                            String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar"),
                            subtitle: String(localized: "settings.app.showPullRequests.subtitle", defaultValue: "Display review items (PR/MR/etc.) with status and number.")
                        ) {
                            Toggle("", isOn: $sidebarShowPullRequest)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .disabled(sidebarHideAllDetails)
                        SettingsCardDivider()
                        SettingsCardRow(
                            configurationReview: .json("sidebar.watchGitStatus"),
                            String(localized: "settings.app.watchGitStatus", defaultValue: "Watch Git Status in Sidebar"),
                            subtitle: String(localized: "settings.app.watchGitStatus.subtitle", defaultValue: "Update sidebar branch and PR metadata from repository file changes without polling git.")
                        ) {
                            Toggle("", isOn: $sidebarWatchGitStatus)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .disabled(sidebarHideAllDetails)
                        SettingsCardDivider()
                        SettingsCardRow(configurationReview: .json("sidebar.makePullRequestsClickable"), String(localized: "settings.app.makeSidebarPullRequestClickable", defaultValue: "Make Sidebar PR Clickable"), subtitle: String(localized: "settings.app.makeSidebarPullRequestClickable.subtitle", defaultValue: "Review items stay visible as plain text, and clicks in that area select the workspace row.")) { Toggle("", isOn: $sidebarMakePullRequestClickable).labelsHidden().controlSize(.small).accessibilityIdentifier("SettingsSidebarPullRequestClickableToggle") }
                        .disabled(sidebarHideAllDetails || !sidebarShowPullRequest)
                        SettingsCardDivider()
                        SettingsCardRow(
                            configurationReview: .json("sidebar.openPullRequestLinksInCmuxBrowser"),
                            String(localized: "settings.app.openSidebarPRLinks", defaultValue: "Open Sidebar PR Links in cmux Browser"),
                            subtitle: !sidebarShowPullRequest ? String(localized: "settings.app.openSidebarPRLinks.subtitleHidden", defaultValue: "Enable sidebar PR visibility to choose where PR links open.") : (!sidebarMakePullRequestClickable ? String(localized: "settings.app.openSidebarPRLinks.subtitleDisabled", defaultValue: "Enable sidebar PR clickability to choose where PR links open.") : (openSidebarPullRequestLinksInCmuxBrowser ? String(localized: "settings.app.openSidebarPRLinks.subtitleOn", defaultValue: "Clicks open inside cmux browser.") : String(localized: "settings.app.openSidebarPRLinks.subtitleOff", defaultValue: "Clicks open in your default browser.")))
                        ) { Toggle("", isOn: $openSidebarPullRequestLinksInCmuxBrowser).labelsHidden().controlSize(.small) }
                        .disabled(sidebarHideAllDetails || !sidebarShowPullRequest || !sidebarMakePullRequestClickable)
                        SettingsCardDivider()
                        SettingsCardRow(
                            configurationReview: .json("sidebar.openPortLinksInCmuxBrowser"),
                            String(localized: "settings.app.openSidebarPortLinks", defaultValue: "Open Sidebar Port Links in cmux Browser"),
                            subtitle: openSidebarPortLinksInCmuxBrowser
                                ? String(localized: "settings.app.openSidebarPortLinks.subtitleOn", defaultValue: "Port clicks open inside cmux browser.")
                                : String(localized: "settings.app.openSidebarPortLinks.subtitleOff", defaultValue: "Port clicks open in your default browser.")
                        ) {
                            Toggle("", isOn: $openSidebarPortLinksInCmuxBrowser)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .disabled(sidebarHideAllDetails)

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("sidebar.showSSH"),
                            String(localized: "settings.app.showSSH", defaultValue: "Show SSH in Sidebar"),
                            subtitle: String(localized: "settings.app.showSSH.subtitle", defaultValue: "Display the SSH target for remote workspaces in its own row.")
                        ) {
                            Toggle("", isOn: $sidebarShowSSH)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .disabled(sidebarHideAllDetails)

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("sidebar.showPorts"),
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
                            configurationReview: .json("sidebar.showLog"),
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
                            configurationReview: .json("sidebar.showProgress"),
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
                            configurationReview: .json("sidebar.showCustomMetadata"),
                            String(localized: "settings.app.showMetadata", defaultValue: "Show Custom Metadata in Sidebar"),
                            subtitle: String(localized: "settings.app.showMetadata.subtitle", defaultValue: "Display custom metadata from report_meta/set_status and report_meta_block.")
                        ) {
                            Toggle("", isOn: $sidebarShowMetadata)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .disabled(sidebarHideAllDetails)
                    }

                    BetaFeaturesSettingsView(
                        dockEnabled: $rightSidebarDockEnabled
                    )

                    SettingsSectionHeader(title: String(localized: "settings.section.automation", defaultValue: "Automation"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .automation))
                    SettingsCard {
                        SettingsPickerRow(
                            configurationReview: .json("automation.socketControlMode"),
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
                                configurationReview: .json("automation.socketPassword"),
                                String(localized: "settings.automation.socketPassword", defaultValue: "Socket Password"),
                                subtitle: hasSocketPasswordConfigured
                                    ? String(localized: "settings.automation.socketPassword.subtitleSet", defaultValue: "Stored in Application Support.")
                                    : String(localized: "settings.automation.socketPassword.subtitleUnset", defaultValue: "No password set. External clients will be blocked until one is configured.")
                            ) {
                                HStack(spacing: 8) {
                                    SecureField(String(localized: "settings.automation.socketPassword.placeholder", defaultValue: "Password"), text: $draftState.socketPasswordDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 170)
                                    Button(hasSocketPasswordConfigured ? String(localized: "settings.automation.socketPassword.change", defaultValue: "Change") : String(localized: "settings.automation.socketPassword.set", defaultValue: "Set")) {
                                        saveSocketPassword()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(draftState.socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                            configurationReview: .json("automation.claudeCodeIntegration"),
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
                        SettingsCardRow(
                            configurationReview: .json("automation.claudeBinaryPath"),
                            String(localized: "settings.automation.claudeCode.customPath", defaultValue: "Claude Binary Path"),
                            subtitle: String(localized: "settings.automation.claudeCode.customPath.subtitle", defaultValue: "Custom path to the claude binary. Leave empty to use PATH.")
                        ) {
                            TextField(
                                String(localized: "settings.automation.claudeCode.customPath.placeholder", defaultValue: "e.g. /usr/local/bin/claude"),
                                text: $customClaudePath
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        }
                    }

                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .json("automation.ripgrepBinaryPath"),
                            String(localized: "settings.automation.ripgrep.customPath", defaultValue: "Ripgrep Binary Path"),
                            subtitle: String(localized: "settings.automation.ripgrep.customPath.subtitle", defaultValue: "Custom path to the rg binary used by Find. Leave empty to use common install locations and PATH.")
                        ) {
                            TextField(
                                String(localized: "settings.automation.ripgrep.customPath.placeholder", defaultValue: "e.g. /etc/profiles/per-user/you/bin/rg"),
                                text: $customRipgrepPath
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        }
                    }

                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .json("automation.suppressSubagentNotifications"),
                            String(localized: "settings.automation.suppressSubagentNotifications", defaultValue: "Suppress Subagent Notifications"),
                            subtitle: suppressSubagentNotifications
                                ? String(localized: "settings.automation.suppressSubagentNotifications.subtitleOn", defaultValue: "Child agent completions stay in Feed without notifications.")
                                : String(localized: "settings.automation.suppressSubagentNotifications.subtitleOff", defaultValue: "Child agent completions notify like top-level agents.")
                        ) {
                            Toggle("", isOn: $suppressSubagentNotifications)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsSuppressSubagentNotificationsToggle")
                        }

                        SettingsCardDivider()

                        SettingsCardNote(String(localized: "settings.automation.suppressSubagentNotifications.note", defaultValue: "Uses process ancestry from hook processes. Disable if nested Codex or Claude sessions should trigger completion notifications."))
                    }

                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .json("automation.cursorIntegration"),
                            String(localized: "settings.automation.cursor", defaultValue: "Cursor Integration"),
                            subtitle: cursorHooksEnabled
                                ? String(localized: "settings.automation.cursor.subtitleOn", defaultValue: "Sidebar shows Cursor agent status and notifications.")
                                : String(localized: "settings.automation.cursor.subtitleOff", defaultValue: "Cursor runs without cmux integration.")
                        ) {
                            Toggle("", isOn: $cursorHooksEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsCursorHooksToggle")
                        }

                        SettingsCardDivider()

                        SettingsCardNote(String(localized: "settings.automation.cursor.note", defaultValue: "Hooks must be installed with `cmux hooks cursor install`. They no-op outside cmux terminals."))
                    }

                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .json("automation.geminiIntegration"),
                            String(localized: "settings.automation.gemini", defaultValue: "Gemini CLI Integration"),
                            subtitle: geminiHooksEnabled
                                ? String(localized: "settings.automation.gemini.subtitleOn", defaultValue: "Sidebar shows Gemini session status and notifications.")
                                : String(localized: "settings.automation.gemini.subtitleOff", defaultValue: "Gemini runs without cmux integration.")
                        ) {
                            Toggle("", isOn: $geminiHooksEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsGeminiHooksToggle")
                        }

                        SettingsCardDivider()

                        SettingsCardNote(String(localized: "settings.automation.gemini.note", defaultValue: "Hooks must be installed with `cmux hooks gemini install`. They no-op outside cmux terminals."))
                    }

                    SettingsCard {
                        SettingsCardRow(configurationReview: .json("automation.portBase"), String(localized: "settings.automation.portBase", defaultValue: "Port Base"), subtitle: String(localized: "settings.automation.portBase.subtitle", defaultValue: "Starting port for CMUX_PORT env var."), controlWidth: pickerColumnWidth) {
                            TextField("", value: $cmuxPortBase, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(configurationReview: .json("automation.portRange"), String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"), subtitle: String(localized: "settings.automation.portRange.subtitle", defaultValue: "Number of ports per workspace."), controlWidth: pickerColumnWidth) {
                            TextField("", value: $cmuxPortRange, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                        }

                        SettingsCardDivider()

                        SettingsCardNote(String(localized: "settings.automation.port.note", defaultValue: "Each workspace gets CMUX_PORT and CMUX_PORT_END env vars with a dedicated port range. New terminals inherit these values."))
                    }

                    SettingsSectionHeader(title: String(localized: "settings.section.browser", defaultValue: "Browser"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .browser))
                        .accessibilityIdentifier("SettingsBrowserSection")
                    SettingsCard {
                        browserEnabledSettingsRows

                        SettingsPickerRow(
                            configurationReview: .json("browser.defaultSearchEngine"),
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

                        if browserSearchEngine == BrowserSearchEngine.custom.rawValue {
                            SettingsCardRow(
                                configurationReview: .json("browser.customSearchEngineName"),
                                String(localized: "settings.browser.customSearchEngineName", defaultValue: "Custom Search Engine Name"),
                                subtitle: String(localized: "settings.browser.customSearchEngineName.subtitle", defaultValue: "Shown in browser address bar search suggestions."),
                                controlWidth: pickerColumnWidth
                            ) {
                                TextField("", text: $browserCustomSearchEngineName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            SettingsCardDivider()

                            SettingsCardRow(
                                configurationReview: .json("browser.customSearchEngineURLTemplate"),
                                String(localized: "settings.browser.customSearchEngineURLTemplate", defaultValue: "Custom Search URL"),
                                subtitle: String(localized: "settings.browser.customSearchEngineURLTemplate.subtitle", defaultValue: "Use {query} or %s for the search terms. Without a placeholder, cmux appends q=."),
                                controlWidth: 330
                            ) {
                                TextField("", text: $browserCustomSearchEngineURLTemplate)
                                    .textFieldStyle(.roundedBorder)
                            }

                            SettingsCardDivider()
                        }

                        SettingsCardRow(configurationReview: .json("browser.showSearchSuggestions"), String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions")) {
                            Toggle("", isOn: $browserSearchSuggestionsEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsPickerRow(
                            configurationReview: .json("browser.theme"),
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
                            configurationReview: .json("browser.discardHiddenWebViews"),
                            String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"),
                            subtitle: browserHiddenWebViewDiscardSubtitle,
                            searchAnchorID: SettingsSearchIndex.settingID(for: .browser, idSuffix: "hidden-webview-discard")
                        ) {
                            Toggle("", isOn: $browserHiddenWebViewDiscardEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsBrowserHiddenWebViewDiscardToggle")
                                .accessibilityLabel(String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"))
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("browser.hiddenWebViewDiscardDelaySeconds"),
                            String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"),
                            subtitle: browserHiddenWebViewDiscardDelaySubtitle,
                            controlWidth: pickerColumnWidth,
                            searchAnchorID: SettingsSearchIndex.settingID(for: .browser, idSuffix: "hidden-webview-discard-delay")
                        ) {
                            HStack(spacing: 8) {
                                Text(browserHiddenWebViewDiscardDelayLabel)
                                    .font(.system(.body, design: .monospaced))
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)

                                Stepper(
                                    "",
                                    value: browserHiddenWebViewDiscardDelayBinding,
                                    in: BrowserHiddenWebViewDiscardPolicy.minimumHiddenDelay...BrowserHiddenWebViewDiscardPolicy.maximumHiddenDelay,
                                    step: 30
                                )
                                .labelsHidden()
                                .accessibilityLabel(String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"))
                                .accessibilityValue(browserHiddenWebViewDiscardDelayLabel)
                            }
                            .disabled(!browserHiddenWebViewDiscardEnabled)
                            .accessibilityIdentifier("SettingsBrowserHiddenWebViewDiscardDelayStepper")
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("browser.openTerminalLinksInCmuxBrowser"),
                            String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in cmux Browser"),
                            subtitle: String(localized: "settings.browser.openTerminalLinks.subtitle", defaultValue: "When off, links clicked in terminal output open in your default browser.")
                        ) {
                            Toggle("", isOn: $openTerminalLinksInCmuxBrowser)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("browser.interceptTerminalOpenCommandInCmuxBrowser"),
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
                                    configurationReview: .json("browser.hostsToOpenInEmbeddedBrowser"),
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
                                    configurationReview: .json("browser.urlsToAlwaysOpenExternally"),
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

                            Text(String(localized: "settings.browser.httpAllowlist.description", defaultValue: "Controls which HTTP (non-HTTPS) hosts can open in cmux without a warning prompt. Defaults include localhost, *.localhost, 127.0.0.1, ::1, 0.0.0.0, and *.localtest.me."))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $draftState.browserInsecureHTTPAllowlistDraft)
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
                                    Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, *.localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
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
                                    Text(String(localized: "settings.browser.httpAllowlist.hint", defaultValue: "One host or wildcard per line (for example: localhost, *.localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me)."))
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
                        .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .browser, idSuffix: "http-allowlist"))

                        SettingsCardDivider()

                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "settings.browser.import", defaultValue: "Import Browser Data"))
                                    .font(.system(size: 13, weight: .semibold))

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(String(localized: "browser.import.hint.title", defaultValue: "Import browser data"))
                                        .font(.system(size: 12.5, weight: .semibold))

                                    Text(browserImportSubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("SettingsBrowserImportSummary")

                                    Text(String(localized: "browser.import.hint.settingsFootnote", defaultValue: "You can always find this in Settings > Browser."))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                                )
                            }

                            HStack(spacing: 8) {
                                Button(String(localized: "settings.browser.import.choose", defaultValue: "Choose…")) {
                                    DispatchQueue.main.async {
                                        BrowserDataImportCoordinator.shared.presentImportDialog()
                                        refreshDetectedImportBrowsers()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsBrowserImportChooseButton")

                                Button(String(localized: "settings.browser.import.refresh", defaultValue: "Refresh")) {
                                    refreshDetectedImportBrowsers()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isDetectingImportBrowsers)
                            }
                            .accessibilityIdentifier("SettingsBrowserImportActions")

                            Toggle(
                                String(localized: "settings.browser.import.hint.show", defaultValue: "Show import hint on blank browser tabs"),
                                isOn: browserImportHintVisibilityBinding
                            )
                            .controlSize(.small)
                            .accessibilityIdentifier("SettingsBrowserImportHintToggle")
                            .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .browserImport, idSuffix: "import-hint"))

                            Text(browserImportHintSettingsNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .settingsSearchAnchors([
                            SettingsSearchIndex.sectionID(for: .browserImport),
                            SettingsSearchIndex.settingID(for: .browserImport, idSuffix: "import-data")
                        ])
                        .accessibilityIdentifier("SettingsBrowserImportSection")
                        .settingsLazyLoadTrigger(.browserImport)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("browser.reactGrabVersion"),
                            String(localized: "settings.browser.reactGrabVersion", defaultValue: "React Grab Version"),
                            subtitle: String(localized: "settings.browser.reactGrabVersion.subtitle", defaultValue: "Pinned npm version of react-grab injected by the toolbar button (Cmd+Shift+G). Only versions with a known integrity hash are accepted.")
                        ) {
                            TextField("", text: $reactGrabVersion)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .font(.system(.body, design: .monospaced))
                                .accessibilityIdentifier("SettingsReactGrabVersionField")
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .action,
                            String(localized: "settings.browser.history", defaultValue: "Browsing History"),
                            subtitle: browserHistorySubtitle,
                            searchAnchorID: SettingsSearchIndex.settingID(for: .browser, idSuffix: "history")
                        ) {
                            Button(String(localized: "settings.browser.history.clearButton", defaultValue: "Clear History…")) {
                                showClearBrowserHistoryConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!didLoadBrowserHistoryForSettings || browserHistoryEntryCount == 0)
                        }
                        .settingsLazyLoadTrigger(.browserHistory)
                    }

                    GlobalHotkeySection()

                    SettingsSectionHeader(title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .keyboardShortcuts))
                        .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .action,
                            String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"),
                            subtitle: String(localized: "settings.shortcuts.chords.subtitle", defaultValue: "Add tmux-style multi-step shortcuts in cmux.json, for example [\"ctrl+b\", \"c\"]."),
                            searchAnchorID: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcut-chords")
                        ) {
                            HStack(spacing: 8) {
                                Link(String(localized: "settings.shortcuts.chords.docsButton", defaultValue: "Chord docs"), destination: shortcutChordsDocsURL)
                                    .font(.caption)
                                    .accessibilityIdentifier("SettingsKeyboardShortcutsChordDocsLink")

                                Button(String(localized: "settings.app.settingsFile.openButton", defaultValue: "Open cmux.json")) {
                                    openCmuxSettingsFileInEditor()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsKeyboardShortcutsOpenSettingsFileButton")
                            }
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .settingsOnly,
                            String(localized: "settings.shortcuts.resetDefaults", defaultValue: "Reset Default Shortcuts"),
                            subtitle: String(localized: "settings.shortcuts.resetDefaults.subtitle", defaultValue: "Restore built-in shortcut values for shortcuts managed in app settings."),
                            searchAnchorID: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "reset-defaults")
                        ) {
                            Button {
                                resetDefaultShortcuts()
                            } label: {
                                Label(
                                    String(localized: "settings.shortcuts.resetDefaults.button", defaultValue: "Reset Defaults"),
                                    systemImage: "arrow.counterclockwise"
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("SettingsKeyboardShortcutsResetDefaultsButton")
                        }

                        SettingsCardDivider()

                        let actions = KeyboardShortcutSettings.settingsVisibleActions
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
                    .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts"))

                    Text(String(localized: "settings.shortcuts.recordHint", defaultValue: "Click a shortcut value to record. Use X to unbind; it changes to restore after a clear."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 2)
                        .accessibilityIdentifier("ShortcutRecordingHint")

                    SettingsSectionHeader(title: String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .workspaceColors))
                    SettingsCard {
                        SettingsPickerRow(
                            configurationReview: .json("workspaceColors.indicatorStyle"),
                            String(localized: "settings.workspaceColors.indicator", defaultValue: "Workspace Color Indicator"),
                            controlWidth: pickerColumnWidth,
                            selection: sidebarIndicatorStyleSelection
                        ) {
                            ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("workspaceColors.selectionColor"),
                            String(localized: "settings.workspaceColors.selectionColor", defaultValue: "Selection Highlight"),
                            subtitle: String(localized: "settings.workspaceColors.selectionColor.subtitle", defaultValue: "Background color of the selected workspace in the sidebar.")
                        ) {
                            HStack(spacing: 8) {
                                if sidebarSelectionColorHex != nil {
                                    Button(String(localized: "settings.workspaceColors.selectionColor.reset", defaultValue: "Reset")) {
                                        sidebarSelectionColorHex = nil
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                ColorPicker(
                                    "",
                                    selection: selectionColorBinding,
                                    supportsOpacity: false
                                )
                                .labelsHidden()
                                .frame(width: 38)

                                Text(sidebarSelectionColorHex ?? String(localized: "settings.sidebarAppearance.defaultLabel", defaultValue: "Default"))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .trailing)
                            }
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .json("workspaceColors.notificationBadgeColor"),
                            String(localized: "settings.workspaceColors.notificationBadgeColor", defaultValue: "Notification Badge"),
                            subtitle: String(localized: "settings.workspaceColors.notificationBadgeColor.subtitle", defaultValue: "Color of the unread notification badge on workspace tabs.")
                        ) {
                            HStack(spacing: 8) {
                                if sidebarNotificationBadgeColorHex != nil {
                                    Button(String(localized: "settings.workspaceColors.notificationBadgeColor.reset", defaultValue: "Reset")) {
                                        sidebarNotificationBadgeColorHex = nil
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                ColorPicker(
                                    "",
                                    selection: notificationBadgeColorBinding,
                                    supportsOpacity: false
                                )
                                .labelsHidden()
                                .frame(width: 38)

                                Text(sidebarNotificationBadgeColorHex ?? String(localized: "settings.sidebarAppearance.defaultLabel", defaultValue: "Default"))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .trailing)
                            }
                        }

                        SettingsCardDivider()

                        SettingsCardNote(
                            String(
                                localized: "settings.workspaceColors.dictionaryNote",
                                defaultValue: "Edit cmux.json to add or remove named colors. \"Choose Custom Color...\" still adds local Custom N entries."
                            )
                        )

                        if workspaceTabPaletteEntries.isEmpty {
                            SettingsCardNote(
                                String(
                                    localized: "settings.workspaceColors.emptyPalette",
                                    defaultValue: "No palette entries. Add colors in cmux.json or use \"Choose Custom Color...\" from a workspace context menu."
                                )
                            )
                        } else {
                            ForEach(Array(workspaceTabPaletteEntries.enumerated()), id: \.element.name) { index, entry in
                                if index > 0 {
                                    SettingsCardDivider()
                                }
                                SettingsCardRow(
                                    configurationReview: .json("workspaceColors.colors"),
                                    entry.name,
                                    subtitle: baseTabColorHex(for: entry.name).map {
                                        String(localized: "settings.workspaceColors.base", defaultValue: "Base: \($0)")
                                    } ?? String(
                                        localized: "settings.workspaceColors.customEntry",
                                        defaultValue: "Named palette entry."
                                    )
                                ) {
                                    HStack(spacing: 8) {
                                        ColorPicker(
                                            "",
                                            selection: tabColorBinding(for: entry.name),
                                            supportsOpacity: false
                                        )
                                        .labelsHidden()
                                        .frame(width: 38)

                                        Text(entry.hex)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 76, alignment: .trailing)

                                        if baseTabColorHex(for: entry.name) == nil {
                                            Button(String(localized: "settings.workspaceColors.remove", defaultValue: "Remove")) {
                                                removeWorkspaceColor(named: entry.name)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }
                            }
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .action,
                            String(localized: "settings.workspaceColors.resetPalette", defaultValue: "Reset Palette"),
                            subtitle: String(
                                localized: "settings.workspaceColors.resetPalette.subtitleV2",
                                defaultValue: "Restore the built-in palette and remove extra named colors."
                            ),
                            searchAnchorID: SettingsSearchIndex.settingID(for: .workspaceColors, idSuffix: "palette")
                        ) {
                            Button(String(localized: "settings.workspaceColors.resetPalette.button", defaultValue: "Reset")) {
                                resetWorkspaceTabColors()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    SettingsSectionHeader(title: String(localized: "settings.section.settingsJSON", defaultValue: "cmux.json"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .settingsJSON))
                        .accessibilityIdentifier("SettingsJSONSection")
                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .action,
                            String(localized: "settings.settingsJSON.file", defaultValue: "User config file"),
                            subtitle: String(localized: "settings.settingsJSON.file.subtitle", defaultValue: "Edit cmux-owned app settings, shortcuts, automation, sidebar, notifications, and browser behavior."),
                            controlWidth: 330,
                            searchAnchorID: SettingsSearchIndex.settingID(for: .settingsJSON, idSuffix: "open-file")
                        ) {
                            HStack(spacing: 8) {
                                Text(KeyboardShortcutSettings.settingsFileStore.settingsFileDisplayPath())
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .trailing)

                                Button(String(localized: "settings.settingsJSON.openButton", defaultValue: "Open")) {
                                    openCmuxSettingsFileInEditor()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsJSONOpenButton")
                            }
                            .accessibilityIdentifier("SettingsJSONOpenFileRowActions")
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            configurationReview: .action,
                            String(localized: "settings.settingsJSON.documentation", defaultValue: "Documentation"),
                            subtitle: String(localized: "settings.settingsJSON.documentation.subtitle", defaultValue: "View supported keys, file locations, schema, and reload behavior."),
                            searchAnchorID: SettingsSearchIndex.settingID(for: .settingsJSON, idSuffix: "documentation")
                        ) {
                            Link(String(localized: "settings.settingsJSON.docsButton", defaultValue: "Open Docs"), destination: settingsJSONDocsURL)
                                .font(.caption)
                                .accessibilityIdentifier("SettingsJSONDocsLink")
                        }
                    }

                    SettingsSectionHeader(title: String(localized: "settings.section.reset", defaultValue: "Reset"))
                        .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .reset))
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
                        .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .reset, idSuffix: "reset-all"))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, 20)
                .environment(
                    \.settingsSearchHighlightState,
                    SettingsSearchHighlightState(anchorID: highlightedSearchAnchorID, token: searchHighlightToken, startedAt: searchHighlightStartedAt)
                )
            }
            .coordinateSpace(name: SettingsScrollCoordinateSpace.name)
            .onPreferenceChange(SettingsLazyLoadFramePreferenceKey.self) { frames in
                handleSettingsLazyLoadFrames(frames, viewportHeight: viewportProxy.size.height)
            }
        .toggleStyle(.switch)
        .onAppear {
            notificationStore.refreshAuthorizationStatus()
            browserThemeMode = BrowserThemeSettings.mode(defaults: .standard).rawValue
            browserImportHintVariantRaw = BrowserImportHintSettings.variant(for: browserImportHintVariantRaw).rawValue
            didLoadBrowserHistoryForSettings = BrowserHistoryStore.shared.isLoaded
            browserHistoryEntryCount = didLoadBrowserHistoryForSettings ? BrowserHistoryStore.shared.entries.count : 0
            draftState.syncBrowserInsecureHTTPAllowlistFromSavedValue(browserInsecureHTTPAllowlist)
            reloadWorkspaceTabColorSettings()
            refreshNotificationCustomSoundStatus()
            let target = SettingsWindowPresenter.consumePendingContentNavigationTarget()
                ?? SettingsNavigationTarget(rawValue: selectedSettingsSectionRaw)
                ?? .account
            applySettingsNavigation(
                SettingsNavigationDestination(
                    target: target,
                    anchorID: SettingsSearchIndex.sectionID(for: target),
                    shouldHighlight: false
                ),
                proxy: proxy
            )
        }
        .onChange(of: notificationSound) { _, _ in
            refreshNotificationCustomSoundStatus()
        }
        .onChange(of: notificationSoundCustomFilePath) { _, _ in
            refreshNotificationCustomSoundStatus()
        }
        .onChange(of: browserInsecureHTTPAllowlist) { _, newValue in
            // Keep draft in sync with external changes unless the user has local unsaved edits.
            draftState.syncBrowserInsecureHTTPAllowlistFromSavedValue(newValue)
        }
        .onReceive(BrowserHistoryStore.shared.$entries) { entries in
            guard BrowserHistoryStore.shared.isLoaded else { return }
            didLoadBrowserHistoryForSettings = true
            browserHistoryEntryCount = entries.count
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadWorkspaceTabColorSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notificationName)) { notification in
            guard let destination = SettingsNavigationRequest.destination(from: notification) else { return }
            applySettingsNavigation(destination, proxy: proxy)
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
    }

    private static func validateBypassedSettingsConfigurationReviews() {
        SettingsConfigurationReview.json("browser.insecureHttpHostsAllowedInEmbeddedBrowser").validate()
        SettingsConfigurationReview.json("browser.showImportHintOnBlankTabs").validate()
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
        appearanceMode = AppearanceSettings.selectMode(
            AppearanceSettings.defaultMode,
            source: "settings.resetAll"
        ).rawValue
        appIconMode = AppIconSettings.defaultMode.rawValue
        AppIconSettings.applyIcon(.automatic)
        socketControlMode = SocketControlSettings.defaultMode.rawValue
        claudeCodeHooksEnabled = ClaudeCodeIntegrationSettings.defaultHooksEnabled
        customClaudePath = ""
        customRipgrepPath = ""
        suppressSubagentNotifications = AgentSubagentNotificationSettings.defaultSuppressNotifications
        cursorHooksEnabled = CursorIntegrationSettings.defaultHooksEnabled
        geminiHooksEnabled = GeminiIntegrationSettings.defaultHooksEnabled
        sendAnonymousTelemetry = TelemetrySettings.defaultSendAnonymousTelemetry
        preferredEditorCommand = ""
        CmdClickSupportedFileRouteSettings.setEnabled(CmdClickSupportedFileRouteSettings.defaultValue)
        openSupportedFilesInCmux = CmdClickSupportedFileRouteSettings.defaultValue
        CmdClickMarkdownRouteSettings.setEnabled(CmdClickMarkdownRouteSettings.defaultValue)
        openMarkdownInCmuxViewer = CmdClickMarkdownRouteSettings.defaultValue
        browserSearchEngine = BrowserSearchSettings.defaultSearchEngine.rawValue
        browserCustomSearchEngineName = BrowserSearchSettings.defaultCustomSearchEngineName
        browserCustomSearchEngineURLTemplate = BrowserSearchSettings.defaultCustomSearchEngineURLTemplate
        browserSearchSuggestionsEnabled = BrowserSearchSettings.defaultSearchSuggestionsEnabled
        browserThemeMode = BrowserThemeSettings.defaultMode.rawValue
        BrowserAvailabilitySettings.setDisabled(BrowserAvailabilitySettings.defaultDisabled)
        browserDisabled = BrowserAvailabilitySettings.defaultDisabled
        browserHiddenWebViewDiscardEnabled = BrowserHiddenWebViewDiscardPolicy.defaultEnabled
        browserHiddenWebViewDiscardDelay = BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay
        browserImportHintVariantRaw = BrowserImportHintSettings.defaultVariant.rawValue
        showBrowserImportHintOnBlankTabs = BrowserImportHintSettings.defaultShowOnBlankTabs
        isBrowserImportHintDismissed = BrowserImportHintSettings.defaultDismissed
        rightSidebarDockEnabled = RightSidebarBetaFeatureSettings.defaultDockEnabled
        openTerminalLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenTerminalLinksInCmuxBrowser
        interceptTerminalOpenCommandInCmuxBrowser = BrowserLinkOpenSettings.defaultInterceptTerminalOpenCommandInCmuxBrowser
        browserHostWhitelist = BrowserLinkOpenSettings.defaultBrowserHostWhitelist
        browserExternalOpenPatterns = BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns
        browserInsecureHTTPAllowlist = BrowserInsecureHTTPSettings.defaultAllowlistText
        draftState.browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
        draftState.browserInsecureHTTPAllowlistSyncedValue = BrowserInsecureHTTPSettings.defaultAllowlistText
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
        menuBarOnly = MenuBarOnlySettings.defaultMenuBarOnly
        QuitWarningSettings.setMode(QuitWarningSettings.defaultConfirmQuitMode)
        confirmQuitModeRaw = QuitWarningSettings.defaultConfirmQuitMode.rawValue
        warnBeforeQuitShortcut = QuitWarningSettings.defaultConfirmQuitMode != .never
        warnBeforeClosingTab = CloseTabWarningSettings.defaultWarnBeforeClosingTab
        warnBeforeClosingTabXButton = CloseTabWarningSettings.defaultWarnBeforeClosingTabXButton
        hideTabCloseButton = CloseTabWarningSettings.defaultHideTabCloseButton
        commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
        commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
        newWorkspacePlacement = WorkspacePlacementSettings.defaultPlacement.rawValue
        workspaceInheritWorkingDirectory = WorkspaceWorkingDirectoryInheritanceSettings.defaultValue
        workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        closeWorkspaceOnLastSurfaceShortcut = LastSurfaceCloseShortcutSettings.defaultValue
        paneFirstClickFocusEnabled = PaneFirstClickFocusSettings.defaultEnabled
        let previousShowTerminalScrollBar = showTerminalScrollBar
        showTerminalScrollBar = TerminalScrollBarSettings.defaultShowScrollBar
        if previousShowTerminalScrollBar != showTerminalScrollBar {
            TerminalScrollBarSettings.notifyDidChange()
        }
        textBoxMaxLines = TerminalTextBoxInputSettings.defaultMaxLines
        textBoxMaxLines = TerminalTextBoxInputSettings.defaultMaxLines
        let previousTerminalCopyOnSelect = terminalCopyOnSelect
        terminalCopyOnSelect = TerminalCopyOnSelectSettings.defaultCopyOnSelect
        if previousTerminalCopyOnSelect != terminalCopyOnSelect {
            TerminalCopyOnSelectSettings.notifyDidChange()
        }
        fileDropDefaultBehavior = FileDropBehaviorSettings.defaultBehavior.rawValue
        let previousAutoResumeAgentSessions = autoResumeAgentSessions
        autoResumeAgentSessions = AgentSessionAutoResumeSettings.defaultAutoResumeAgentSessions
        if previousAutoResumeAgentSessions != autoResumeAgentSessions {
            AgentSessionAutoResumeSettings.notifyDidChange()
        }
        AgentHibernationSettings.reset()
        workspaceAutoReorder = WorkspaceAutoReorderSettings.defaultValue
        iMessageMode = IMessageModeSettings.defaultValue
        sidebarHideAllDetails = SidebarWorkspaceDetailSettings.defaultHideAllDetails
        sidebarWrapWorkspaceTitles = SidebarWorkspaceTitleWrapSettings.defaultWrap
        sidebarShowWorkspaceDescription = SidebarWorkspaceDetailSettings.defaultShowWorkspaceDescription
        sidebarShowNotificationMessage = SidebarWorkspaceDetailSettings.defaultShowNotificationMessage
        sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
        sidebarBranchDirectoryStacked = SidebarBranchDirectoryStackedSettings.defaultStacked
        sidebarPathLastSegmentOnly = SidebarPathLastSegmentSettings.defaultLastSegmentOnly
        sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
        sidebarSelectionColorHex = nil
        sidebarNotificationBadgeColorHex = nil
        sidebarShowBranchDirectory = SidebarWorkspaceDetailDefaults.showBranchDirectory
        sidebarShowPullRequest = SidebarWorkspaceDetailDefaults.showPullRequests
        sidebarWatchGitStatus = SidebarWorkspaceDetailDefaults.watchGitStatus
        sidebarMakePullRequestClickable = SidebarPullRequestClickabilitySettings.defaultClickable
        openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
        openSidebarPortLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPortLinksInCmuxBrowser
        sidebarShowSSH = SidebarWorkspaceDetailDefaults.showSSH
        sidebarShowPorts = SidebarWorkspaceDetailDefaults.showPorts
        sidebarShowLog = SidebarWorkspaceDetailDefaults.showLog
        sidebarShowProgress = SidebarWorkspaceDetailDefaults.showProgress
        sidebarShowMetadata = SidebarWorkspaceDetailDefaults.showCustomMetadata
        sidebarTintHex = SidebarTintDefaults.hex
        sidebarTintHexLight = nil
        sidebarTintHexDark = nil
        sidebarTintOpacity = SidebarTintDefaults.opacity
        sidebarMatchTerminalBackground = false
        showOpenAccessConfirmation = false
        pendingOpenAccessMode = nil
        draftState.socketPasswordDraft = ""
        socketPasswordStatusMessage = nil
        socketPasswordStatusIsError = false
        refreshDetectedImportBrowsers()
        SystemWideHotkeySettings.reset()
        KeyboardShortcutSettings.resetAll()
        WorkspaceTabColorSettings.reset()
        reloadWorkspaceTabColorSettings()
        shortcutResetToken = UUID()
        DispatchQueue.main.async { isResettingSettings = false }
    }

    private func resetDefaultShortcuts() {
        KeyboardShortcutRecorderActivity.stopAllRecording()
        for action in KeyboardShortcutSettings.Action.allCases where action != SystemWideHotkeySettings.action {
            KeyboardShortcutSettings.resetShortcut(for: action)
        }
        shortcutResetToken = UUID()
    }

    private func tabColorBinding(for name: String) -> Binding<Color> {
        Binding(
            get: {
                let hex = WorkspaceTabColorSettings.currentColorHex(named: name)
                    ?? WorkspaceTabColorSettings.defaultColorHex(named: name)
                    ?? "#1565C0"
                return Color(nsColor: NSColor(hex: hex) ?? .systemBlue)
            },
            set: { newValue in
                let hex = NSColor(newValue).hexString()
                WorkspaceTabColorSettings.setColor(named: name, hex: hex)
                reloadWorkspaceTabColorSettings()
            }
        )
    }

    private func baseTabColorHex(for name: String) -> String? {
        WorkspaceTabColorSettings.defaultColorHex(named: name)
    }

    private func removeWorkspaceColor(named name: String) {
        WorkspaceTabColorSettings.removeColor(named: name)
        reloadWorkspaceTabColorSettings()
    }

    private func resetWorkspaceTabColors() {
        WorkspaceTabColorSettings.reset()
        reloadWorkspaceTabColorSettings()
    }

    private func reloadWorkspaceTabColorSettings() {
        workspaceTabPaletteEntries = WorkspaceTabColorSettings.palette()
    }

    private func saveBrowserInsecureHTTPAllowlist() {
        browserInsecureHTTPAllowlist = draftState.browserInsecureHTTPAllowlistDraft
        draftState.browserInsecureHTTPAllowlistSyncedValue = draftState.browserInsecureHTTPAllowlistDraft
    }

    private func refreshDetectedImportBrowsers() {
        didRequestBrowserImportDetection = true
        isDetectingImportBrowsers = true
        browserImportDetectionGeneration += 1
        let generation = browserImportDetectionGeneration
        let homeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let bundleLookupSnapshot = InstalledBrowserDetector.applicationBundleLookupSnapshot()
        Task.detached(priority: .userInitiated) {
            let detectedBrowsers = InstalledBrowserDetector.detectInstalledBrowsers(
                homeDirectoryURL: homeDirectoryURL,
                bundleLookup: { bundleLookupSnapshot[$0] }
            )
            await MainActor.run {
                guard generation == browserImportDetectionGeneration else { return }
                detectedImportBrowsers = detectedBrowsers
                isDetectingImportBrowsers = false
            }
        }
    }
}
