import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

/// The process entry point. When the binary is launched with a sidebar worker
/// flag (the app re-executes its own binary that way so a crash in the
/// interpreter or renderer kills only the worker process), run that worker
/// loop instead of the app:
/// - the render worker hosts its own faceless AppKit session and shares the
///   rendered layer tree with the host;
/// - the interpreter worker (stage-1 fallback path) runs before any
///   AppKit/SwiftUI setup.
@main
enum CmuxMain {
    static func main() {
        if CommandLine.arguments.contains(RenderWorkerClient.workerModeArgument) {
            runSidebarRenderWorker()
        }
        if CommandLine.arguments.contains(InterpreterClient.workerModeArgument) {
            runSidebarInterpreterWorker()
            exit(0)
        }
        cmuxApp.main()
    }
}

struct cmuxApp: App {
    /// Dependency container for the new settings packages. Constructed
    /// once at app launch and injected into the SwiftUI environment via
    /// `.settingsRuntime(_:)`; descendant views resolve their settings
    /// through it via the `@LiveSetting` property wrapper.
    private let settingsRuntime: SettingsRuntime

    /// The de-singletonized auth graph (shared AuthCoordinator + the macOS
    /// hosted-browser sign-in flow). Constructed once at app launch and
    /// injected into AppDelegate and the auth-consuming services.
    private let authComposition: MacAuthComposition

    @State var tabManager: TabManager
    @State var notificationStore = TerminalNotificationStore.shared
    @State var closedItemHistoryStore = ClosedItemHistoryStore.shared
    @State var sidebarState = SidebarState()
    @State var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @AppStorage(AppearanceSettings.appearanceModeKey) var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyle = TitlebarControlsStyle.classic.rawValue
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(SocketControlSettings.appStorageKey) var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(BrowserToolbarAccessorySpacingDebugSettings.key) private var browserToolbarAccessorySpacingRaw = BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
    @State var browserFocusModeMenuRevision = 0
    @State var focusHistoryMenuInvalidator = FocusHistoryMenuInvalidator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    private var browserToolbarAccessorySpacing: Int {
        BrowserToolbarAccessorySpacingDebugSettings.resolved(browserToolbarAccessorySpacingRaw)
    }

    init() {
        // Build the settings container once. All injected dependencies
        // (the catalog, the two stores, the error log) live on this
        // single struct; nothing in the package or app references a
        // shared static.
        let settingsCatalog = SettingCatalog()
        let configFileURL = CmuxConfigLocation().userConfigFile
        // Relocate a pre-existing socket password out of the legacy
        // Application Support directory before any store reads it. The CLI reads
        // this file on every agent hook, and a cross-identity reach into
        // Application Support triggers the macOS Sequoia "access data from other
        // apps" prompt; the password now lives in the non-protected cmux state
        // directory (https://github.com/manaflow-ai/cmux/issues/5146). The app
        // owns its Application Support data, so it can perform this move silently.
        // This App initializer is the composition root, so it is where the
        // concrete `FileManager.default` is named for the package's injected seams.
        SocketControlPasswordStore.migrateLegacyApplicationSupportPasswordFileIfNeeded(fileManager: .default)
        // Secrets live in their own 0600 files under the cmux state directory,
        // the same directory (and `socket-control-password` file) the socket
        // auth path reads via SocketControlPasswordStore, so the Settings UI
        // and the listener share one source of truth.
        let secretBaseDirectory = SocketControlPasswordStore.defaultPasswordFileURL(fileManager: .default)?
            .deletingLastPathComponent()
            ?? CmuxStateDirectory.url(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let secretStore = SecretFileStore(baseDirectory: secretBaseDirectory)

        // Lift any plaintext socket-control password out of `cmux.json` into the
        // secure store, then scrub it from the config. This runs here, in the App
        // initializer, on purpose: it completes before the managed-config layer
        // (`CmuxSettingsFileStore`, loaded later during app launch) reads the
        // file, so removing the key can never be misread as a removed managed
        // override that would trigger a restore. The secure file the migration
        // writes is the same one both the Settings UI (via `secretStore`) and the
        // socket listener (via `SocketControlPasswordStore`) read.
        let socketPasswordStore = SocketControlPasswordStore()
        let secretMigrationTimestamp: String = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
            return formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
        }()
        PlaintextSecretMigration.scrub(
            plaintextKeyPath: ["automation", "socketPassword"],
            configURL: configFileURL,
            loadCurrentSecret: { (try? socketPasswordStore.loadPassword()) ?? nil },
            saveSecret: { try socketPasswordStore.savePassword($0) },
            backupTimestamp: secretMigrationTimestamp
        )
        let authComposition = MacAuthComposition()
        self.authComposition = authComposition
        self.settingsRuntime = SettingsRuntime(
            catalog: settingsCatalog,
            userDefaultsStore: UserDefaultsSettingsStore(
                defaults: .standard,
                migrating: settingsCatalog.all
            ),
            jsonStore: JSONConfigStore(fileURL: configFileURL),
            secretStore: secretStore,
            errorLog: SettingsErrorLog(),
            accountFlow: HostAccountFlow(
                coordinator: authComposition.coordinator,
                browserSignIn: authComposition.browserSignIn
            ),
            hostActions: HostSettingsActions(configFileURL: configFileURL)
        )

        // If invoked with CLI-style arguments (e.g. `cmux hooks setup`), exec the
        // bundled CLI at Contents/Resources/bin/cmux. The GUI binary and the CLI
        // share the name `cmux`, so if the GUI's Contents/MacOS leaks onto $PATH
        // (which happens for any shell descended from this process), bare `cmux`
        // resolves here instead of the CLI. See
        // https://github.com/manaflow-ai/cmux/issues/4678.
        // cmux ships a universal binary so it still supports Intel Macs, but a
        // stale LaunchServices architecture preference can pin the app to its
        // x86_64 slice on Apple Silicon, running the whole process tree under
        // Rosetta (macOS 26 deprecation dialog; translated child shells and
        // toolchains). `LSArchitecturePriority` in Info.plist fixes future
        // launches; this corrects an already-mis-pinned install by re-execing the
        // arm64 slice in place. It runs *before* CLI forwarding so a translated
        // GUI binary invoked with CLI-style arguments is re-execed natively first
        // and the forwarded bundled CLI then inherits the native arch too. The
        // re-exec preserves argv and re-enters this initializer, so forwarding
        // proceeds normally in the native process. No-op on Intel and on native
        // launches. See https://github.com/manaflow-ai/cmux/issues/753.
        RosettaNativeRelaunch.relaunchNativelyIfNeeded()

        CLIForwardingLaunchRouter.forwardToBundledCLIIfNeeded()

        StartupBreadcrumbLog.append("app.init.begin")
        UITestLaunchManifest.applyIfPresent()
        StartupBreadcrumbLog.append("app.init.uiTestManifest.applied")

        if SocketControlSettings.shouldBlockUntaggedDebugLaunch() {
            StartupBreadcrumbLog.append("app.init.blockUntaggedDebugLaunch")
            Self.terminateForMissingLaunchTag()
        }

        Self.configureGhosttyEnvironment()
        StartupBreadcrumbLog.append("app.init.ghosttyEnvironment.configured")
        _ = KeyboardShortcutSettings.settingsFileStore
        StartupBreadcrumbLog.append("app.init.keyboardShortcuts.loaded")

        // Apply saved language preference before any UI loads
        LanguageSettings.apply(LanguageSettings.languageAtLaunch)
        StartupBreadcrumbLog.append("app.init.language.applied")

        let startupAppearance = AppearanceSettings.resolvedMode()
        Self.applyAppearance(startupAppearance, duringLaunch: true)
        StartupBreadcrumbLog.append("app.init.appearance.applied", fields: ["mode": startupAppearance.rawValue])
        let defaults = UserDefaults.standard
        AppBundleIconPersistencePolicy.updateDisableDefault(
            defaults: defaults,
            launchArguments: ProcessInfo.processInfo.arguments
        )
        KeyboardShortcutSettings.settingsFileStore.applyDeferredManagedDefaultSideEffects()
        StartupBreadcrumbLog.append("app.init.keyboardShortcuts.sideEffectsApplied")
        StartupBreadcrumbLog.append("app.init.tabManager.begin")
        _tabManager = State(initialValue: TabManager())
        StartupBreadcrumbLog.append("app.init.tabManager.complete")
        // Migrate legacy and old-format socket mode values to the new enum.
        if let stored = defaults.string(forKey: SocketControlSettings.appStorageKey) {
            let migrated = SocketControlSettings.migrateMode(stored)
            if migrated.rawValue != stored {
                defaults.set(migrated.rawValue, forKey: SocketControlSettings.appStorageKey)
            }
        } else if let legacy = defaults.object(forKey: SocketControlSettings.legacyEnabledKey) as? Bool {
            defaults.set(legacy ? SocketControlMode.cmuxOnly.rawValue : SocketControlMode.off.rawValue,
                         forKey: SocketControlSettings.appStorageKey)
        }
        // Skip keychain migration for DEV/staging builds. Each tagged build gets a
        // unique bundle ID with its own UserDefaults domain, so migration would run
        // on every launch and trigger a macOS keychain access prompt (the legacy
        // keychain item was created by a differently-signed app).
        let bundleID = Bundle.main.bundleIdentifier
        if !SocketControlSettings.isDebugLikeBundleIdentifier(bundleID)
            && !SocketControlSettings.isStagingBundleIdentifier(bundleID) {
            StartupBreadcrumbLog.append("app.init.keychainMigration.begin")
            SocketControlPasswordStore().migrateLegacyKeychainPasswordIfNeeded(defaults: defaults)
            StartupBreadcrumbLog.append("app.init.keychainMigration.complete")
        }
        migrateSidebarAppearanceDefaultsIfNeeded(defaults: defaults)
        StartupBreadcrumbLog.append("app.init.sidebarDefaults.migrated")

        // UI tests depend on AppDelegate wiring happening even if SwiftUI view appearance
        // callbacks (e.g. `.onAppear`) are delayed or skipped.
        StartupBreadcrumbLog.append("app.init.delegate.configure.begin")
        appDelegate.configure(
            tabManager: tabManager,
            notificationStore: notificationStore,
            sidebarState: sidebarState,
            settingsRuntime: settingsRuntime,
            auth: authComposition
        )
        StartupBreadcrumbLog.append("app.init.delegate.configured")
    }

    var body: some Scene {
        WindowGroup {
            MainWindowBootstrapView()
                .settingsRuntime(settingsRuntime)
                .cmuxAppearanceColorScheme(appearanceMode)
                .onAppear {
                    SettingsWindowPresenter.configure(
                        openWindow: {
                            openWindow(id: SettingsWindowPresenter.windowID)
                        },
                        parentWindowProvider: {
                            AppDelegate.shared?.preferredMainWindowForSettingsPresentation()
                        }
                    )
#if DEBUG
                    if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1" {
                        AppDelegate.shared?.updateLog.append("ui test: cmuxApp onAppear")
                    }
#endif
                    bootstrapMainWindowScene()
                }
                .onChange(of: appearanceMode) { _ in
                    applyAppearance()
                }
                .onChange(of: socketControlMode) { _ in
                    updateSocketController()
                }
                .onReceive(NotificationCenter.default.publisher(for: .browserFocusModeStateDidChange)) { _ in
                    browserFocusModeMenuRevision &+= 1
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                splitCommandButton(title: String(localized: "menu.app.settings", defaultValue: "Settings…"), shortcut: menuShortcut(for: .openSettings)) {
                    appDelegate.openPreferencesWindow(debugSource: "menu.cmdComma")
                }
                Button(String(localized: "menu.app.openCmuxSettingsFile", defaultValue: "Open cmux.json")) {
                    openCmuxSettingsFileInEditor()
                }
                Button(String(localized: "menu.app.ghosttySettings", defaultValue: "Ghostty Settings…")) {
                    GhosttyApp.shared.openConfigurationInTextEdit()
                }
                splitCommandButton(title: String(localized: "menu.app.reloadConfiguration", defaultValue: "Reload Configuration"), shortcut: menuShortcut(for: .reloadConfiguration)) {
                    dispatchReloadConfigurationMenuCommand()
                }
                Button(String(localized: "menu.app.makeDefaultTerminal", defaultValue: "Make cmux the Default Terminal")) {
                    DefaultTerminalUserAction.setAsDefault(debugSource: "menu.makeDefaultTerminal")
                }
            }

            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "menu.app.about", defaultValue: "About cmux")) {
                    showAboutPanel()
                }
                Button(String(localized: "menu.app.checkForUpdates", defaultValue: "Check for Updates…")) {
                    appDelegate.checkForUpdates(nil)
                }
                InstallUpdateMenuItem(model: appDelegate.updateViewModel)
            }

            CommandGroup(replacing: .appTermination) {
                splitCommandButton(title: String(localized: "menu.quitCmux", defaultValue: "Quit cmux"), shortcut: menuShortcut(for: .quit)) {
                    NSApp.terminate(nil)
                }
            }

#if DEBUG
            CommandMenu("Update Pill") {
                Button("Show Update Pill") {
                    appDelegate.showUpdatePill(nil)
                }
                Button("Show Long Nightly Pill") {
                    appDelegate.showUpdatePillLongNightly(nil)
                }
                Button("Show Loading State") {
                    appDelegate.showUpdatePillLoading(nil)
                }
                Button("Hide Update Pill") {
                    appDelegate.hideUpdatePill(nil)
                }
                Button("Automatic Update Pill") {
                    appDelegate.clearUpdatePillOverride(nil)
                }
            }
#endif

            CommandMenu(String(localized: "menu.notifications.title", defaultValue: "Notifications")) {
                let snapshot = notificationMenuSnapshot

                Button(snapshot.stateHintTitle) {}
                    .disabled(true)

                if !snapshot.recentNotifications.isEmpty {
                    Divider()

                    ForEach(snapshot.recentNotifications) { notification in
                        Button(notificationMenuItemTitle(for: notification)) {
                            openNotificationFromMainMenu(notification)
                        }
                    }

                    Divider()
                }

                splitCommandButton(title: String(localized: "menu.notifications.show", defaultValue: "Show Notifications"), shortcut: menuShortcut(for: .showNotifications)) {
                    showNotificationsPopover()
                }

                splitCommandButton(title: String(localized: "menu.notifications.jumpToUnread", defaultValue: "Jump to Latest Unread"), shortcut: menuShortcut(for: .jumpToUnread)) {
                    appDelegate.jumpToLatestUnread()
                }
                .disabled(!snapshot.hasUnreadNotifications)

                splitCommandButton(title: String(localized: "menu.notifications.toggleUnread", defaultValue: "Toggle Unread"), shortcut: menuShortcut(for: .toggleUnread)) {
                    appDelegate.toggleFocusedNotificationUnread()
                }
                .disabled(activeTabManager.selectedWorkspace == nil)

                Button(String(localized: "menu.notifications.markAllRead", defaultValue: "Mark All Read")) {
                    notificationStore.markAllRead()
                }
                .disabled(!snapshot.hasUnreadNotifications)

                Button(String(localized: "menu.notifications.clearAll", defaultValue: "Clear All")) {
                    notificationStore.clearAll()
                }
                .disabled(!snapshot.hasNotifications)
            }

#if DEBUG
            CommandMenu("Debug") {
                Button("New Tab With Lorem Search Text") {
                    appDelegate.openDebugLoremTab(nil)
                }

                Button("New Tab With Large Scrollback") {
                    appDelegate.openDebugScrollbackTab(nil)
                }

                AgentSessionDebugMenuButtons(
                    openReact: { appDelegate.openDebugAgentSessionReact(nil) },
                    openSolid: { appDelegate.openDebugAgentSessionSolid(nil) }
                )

                Button("Open Workspaces for All Workspace Colors") {
                    appDelegate.openDebugColorComparisonWorkspaces(nil)
                }

                Button(
                    String(
                        localized: "debug.menu.openStressWorkspacesWithLoadedSurfaces",
                        defaultValue: "Open Stress Workspaces and Load All Terminals"
                    )
                ) {
                    appDelegate.openDebugStressWorkspacesWithLoadedSurfaces(nil)
                }

                Divider()
                Menu("Debug Windows") {
                    Button("Background Debug…") {
                        BackgroundDebugWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.bonsplitTabBarDebug",
                            defaultValue: "Bonsplit Tab Bar Debug…"
                        )
                    ) {
                        BonsplitTabBarDebugWindowController.shared.show()
                    }
                    Button("Browser Import Hint Debug…") {
                        BrowserImportHintDebugWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.browserProfilePopoverDebug",
                            defaultValue: "Browser Profile Popover Debug…"
                        )
                    ) {
                        BrowserProfilePopoverDebugWindowController.shared.show()
                    }
                    Button("Debug Window Controls…") {
                        DebugWindowControlsWindowController.shared.show()
                    }
                    Button("Feed Preview…") {
                        FeedPreviewWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.feedTextEditorDebug",
                            defaultValue: "Feed Text Editor Lab…"
                        )
                    ) {
                        FeedTextEditorDebugWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.feedButtonStyleDebug",
                            defaultValue: "Feed Button Style Debug…"
                        )
                    ) {
                        FeedButtonStyleDebugWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.startupAppearanceDebug",
                            defaultValue: "Startup Appearance Debug…"
                        )
                    ) {
                        StartupAppearanceDebugWindowController.shared.show()
                    }
                    Button("Menu Bar Extra Debug…") {
                        MenuBarExtraDebugWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.aboutTitlebarDebug",
                            defaultValue: "About Titlebar Debug…"
                        )
                    ) {
                        AboutTitlebarDebugWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.titlebarLayoutDebug",
                            defaultValue: "Titlebar Layout Debug..."
                        )
                    ) {
                        TitlebarLayoutDebugWindowController.shared.show()
                    }
                    Button("Sidebar Debug…") {
                        SidebarDebugWindowController.shared.show()
                    }
                    Button("Split Button Layout Debug…") {
                        SplitButtonLayoutDebugWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.tabBarBackdropLab",
                            defaultValue: "Tab Bar Backdrop Lab…"
                        )
                    ) {
                        TabBarBackdropLabWindowController.shared.show()
                    }
                    Button("File Explorer Style Debug…") {
                        FileExplorerStyleDebugWindowController.shared.show()
                    }
                    Button(
                        String(
                            localized: "debug.menu.pdfPreviewChromeDebug",
                            defaultValue: "PDF Preview Chrome Debug…"
                        )
                    ) {
                        PDFPreviewChromeDebugWindowController.shared.show()
                    }
                    Button("Open All Debug Windows") {
                        openAllDebugWindows()
                    }
                }

                Menu(
                    String(
                        localized: "debug.menu.browserToolbarButtonSpacing",
                        defaultValue: "Browser Toolbar Button Spacing"
                    )
                ) {
                    ForEach(BrowserToolbarAccessorySpacingDebugSettings.supportedValues, id: \.self) { spacing in
                        Button {
                            browserToolbarAccessorySpacingRaw = spacing
                        } label: {
                            if browserToolbarAccessorySpacing == spacing {
                                Label {
                                    Text(verbatim: "\(spacing)")
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(verbatim: "\(spacing)")
                            }
                        }
                    }
                }

                Toggle(
                    String(localized: "debug.devBuildBanner.show", defaultValue: "Show Dev Build Banner"),
                    isOn: $showSidebarDevBuildBanner
                )

                Divider()

                Picker("Titlebar Controls Style", selection: $titlebarControlsStyle) {
                    ForEach(TitlebarControlsStyle.allCases) { style in
                        Text(style.menuTitle).tag(style.rawValue)
                    }
                }

                Divider()

                Button(String(localized: "menu.updateLogs.copyUpdateLogs", defaultValue: "Copy Update Logs")) {
                    appDelegate.copyUpdateLogs(nil)
                }
                Button(String(localized: "menu.updateLogs.copyFocusLogs", defaultValue: "Copy Focus Logs")) {
                    appDelegate.copyFocusLogs(nil)
                }

                Divider()

                Button("Trigger Sentry Test Crash") {
                    appDelegate.triggerSentryTestCrash(nil)
                }
            }
#endif

            // New tab commands
            CommandGroup(replacing: .newItem) {
                splitCommandButton(title: String(localized: "menu.file.newWindow", defaultValue: "New Window"), shortcut: menuShortcut(for: .newWindow)) {
                    appDelegate.openNewMainWindow(nil)
                }

                splitCommandButton(title: String(localized: "menu.file.newWorkspace", defaultValue: "New Workspace"), shortcut: menuShortcut(for: .newTab)) {
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.performNewWorkspaceAction(
                            tabManager: activeTabManager,
                            debugSource: "menu.newWorkspace"
                        )
                    } else {
                        activeTabManager.addWorkspace()
                    }
                }

                splitCommandButton(title: String(localized: "menu.file.openFolder", defaultValue: "Open Folder…"), shortcut: menuShortcut(for: .openFolder)) {
                    AppDelegate.shared?.showOpenFolderPanel()
                }

                Button(
                    String(
                        localized: "menu.file.openFolderInVSCodeInline",
                        defaultValue: "Open Folder in VS Code (Inline)…"
                    )
                ) {
                    AppDelegate.shared?.showOpenFolderInInlineVSCodePanel()
                }
                .disabled(!TerminalDirectoryOpenTarget.vscodeInline.isAvailable())
            }

            // Close tab/workspace
            CommandGroup(after: .newItem) {
                splitCommandButton(title: String(localized: "menu.file.goToWorkspace", defaultValue: "Go to Workspace…"), shortcut: menuShortcut(for: .goToWorkspace)) {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteSwitcherRequested, object: targetWindow)
                }

                splitCommandButton(title: String(localized: "menu.file.commandPalette", defaultValue: "Command Palette…"), shortcut: menuShortcut(for: .commandPalette)) {
                    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
                    NotificationCenter.default.post(name: .commandPaletteRequested, object: targetWindow)
                }

                Divider()

                // Terminal semantics:
                // The Close Tab shortcut closes the focused tab/surface with confirmation
                // when needed. By default, closing the last surface also closes the
                // workspace and the window if it was also the last workspace.
                // Users can opt into keeping the workspace open instead.
                splitCommandButton(title: String(localized: "menu.file.closeTab", defaultValue: "Close Tab"), shortcut: menuShortcut(for: .closeTab)) {
                    closePanelOrWindow()
                }

                splitCommandButton(title: String(localized: "menu.file.closeOtherTabs", defaultValue: "Close Other Tabs in Pane"), shortcut: menuShortcut(for: .closeOtherTabsInPane)) {
                    closeOtherTabsInFocusedPane()
                }
                .disabled(!activeTabManager.canCloseOtherTabsInFocusedPane())

                // The Close Workspace shortcut closes the current workspace with confirmation
                // when needed. If this is the last workspace, it closes the window.
                splitCommandButton(title: String(localized: "menu.file.closeWorkspace", defaultValue: "Close Workspace"), shortcut: menuShortcut(for: .closeWorkspace)) {
                    closeTabOrWindow()
                }

                Menu(String(localized: "commandPalette.switcher.workspaceLabel", defaultValue: "Workspace")) {
                    workspaceCommandMenuContent(manager: activeTabManager)
                }

            }

            // Find
            CommandGroup(after: .textEditing) {
                Menu(String(localized: "menu.find.title", defaultValue: "Find")) {
                    let restoreFindTargetFocus = {
                        _ = AppDelegate.shared?.restoreFocusedMainPanelFocusFromRightSidebar(
                            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                        )
                    }

                    splitCommandButton(title: String(localized: "menu.find.find", defaultValue: "Find…"), shortcut: menuShortcut(for: .find)) {
#if DEBUG
                        cmuxDebugLog("find.menu Cmd+F fired")
#endif
                        _ = AppDelegate.shared?.performFindShortcutInActiveMainWindow(
                            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                        )
                    }

                    splitCommandButton(title: String(localized: "menu.find.findInDirectory", defaultValue: "Find in Directory…"), shortcut: menuShortcut(for: .findInDirectory)) {
                        _ = AppDelegate.shared?.focusFileSearchInActiveMainWindow(
                            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                        )
                    }

                    splitCommandButton(title: String(localized: "menu.find.findNext", defaultValue: "Find Next"), shortcut: menuShortcut(for: .findNext)) {
                        restoreFindTargetFocus()
                        activeTabManager.findNext()
                    }

                    splitCommandButton(title: String(localized: "menu.find.findPrevious", defaultValue: "Find Previous"), shortcut: menuShortcut(for: .findPrevious)) {
                        restoreFindTargetFocus()
                        activeTabManager.findPrevious()
                    }

                    Divider()

                    splitCommandButton(title: String(localized: "menu.find.hideFindBar", defaultValue: "Hide Find Bar"), shortcut: menuShortcut(for: .hideFind)) {
                        restoreFindTargetFocus()
                        activeTabManager.hideFind()
                    }
                    .disabled(!(activeTabManager.isFindVisible))

                    Divider()

                    splitCommandButton(title: String(localized: "menu.find.useSelectionForFind", defaultValue: "Use Selection for Find"), shortcut: menuShortcut(for: .useSelectionForFind)) {
                        restoreFindTargetFocus()
                        activeTabManager.searchSelection()
                    }
                    .disabled(!(activeTabManager.canUseSelectionForFind))

                    Divider()

                    splitCommandButton(title: String(localized: "menu.find.sendCtrlFToTerminal", defaultValue: "Send Ctrl-F to Terminal"), shortcut: menuShortcut(for: .sendCtrlFToTerminal)) {
                        // Restore focus to the terminal if the right sidebar grabbed it, then
                        // forward a faithfully-encoded Ctrl-F (e.g. Claude Code force-stop).
                        restoreFindTargetFocus()
                        if !activeTabManager.sendCtrlFToFocusedTerminal() {
                            NSSound.beep()
                        }
                    }
                    .disabled(activeTabManager.selectedTerminalPanel == nil)
                }
            }

            windowAndViewCommands
        }

        Window(String(localized: "settings.title", defaultValue: "Settings"), id: SettingsWindowPresenter.windowID) {
            SettingsWindowRoot(runtime: settingsRuntime)
                .settingsRuntime(settingsRuntime)
                .background(WindowAccessor(dedupeByWindow: false) { window in
                    SettingsWindowPresenter.configure(window: window)
                })
                .cmuxAppearanceColorScheme(appearanceMode)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
        }

        Window(String(localized: "settings.config.windowTitle", defaultValue: "Config"), id: ConfigSettingsView.windowID) {
            ConfigSettingsView()
                .settingsRuntime(settingsRuntime)
                .cmuxAppearanceColorScheme(appearanceMode)
        }
    }

}

private struct MainWindowBootstrapView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(WindowAccessor { window in
                window.identifier = NSUserInterfaceItemIdentifier("cmux.bootstrap")
                window.isRestorable = false
                window.orderOut(nil)
                Task { @MainActor [weak window] in
                    window?.orderOut(nil)
                    window?.close()
                }
            })
    }
}


