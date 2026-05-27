import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers
@main
struct cmuxApp: App {
    @StateObject private var tabManager: TabManager
    @StateObject private var notificationStore = TerminalNotificationStore.shared
    @StateObject var closedItemHistoryStore = ClosedItemHistoryStore.shared
    @StateObject private var sidebarState = SidebarState()
    @StateObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyle = TitlebarControlsStyle.classic.rawValue
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(BrowserToolbarAccessorySpacingDebugSettings.key) private var browserToolbarAccessorySpacingRaw = BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
    @StateObject var focusHistoryMenuInvalidator = FocusHistoryMenuInvalidator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    private var browserToolbarAccessorySpacing: Int {
        BrowserToolbarAccessorySpacingDebugSettings.resolved(browserToolbarAccessorySpacingRaw)
    }

    init() {
        // If invoked with CLI-style arguments (e.g. `cmux hooks setup`), exec the
        // bundled CLI at Contents/Resources/bin/cmux. The GUI binary and the CLI
        // share the name `cmux`, so if the GUI's Contents/MacOS leaks onto $PATH
        // (which happens for any shell descended from this process), bare `cmux`
        // resolves here instead of the CLI. See
        // https://github.com/manaflow-ai/cmux/issues/4678.
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
        _tabManager = StateObject(wrappedValue: TabManager())
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
            SocketControlPasswordStore.migrateLegacyKeychainPasswordIfNeeded(defaults: defaults)
            StartupBreadcrumbLog.append("app.init.keychainMigration.complete")
        }
        migrateSidebarAppearanceDefaultsIfNeeded(defaults: defaults)
        StartupBreadcrumbLog.append("app.init.sidebarDefaults.migrated")

        // UI tests depend on AppDelegate wiring happening even if SwiftUI view appearance
        // callbacks (e.g. `.onAppear`) are delayed or skipped.
        StartupBreadcrumbLog.append("app.init.delegate.configure.begin")
        appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore, sidebarState: sidebarState)
        StartupBreadcrumbLog.append("app.init.delegate.configured")
    }

    private static func terminateForMissingLaunchTag() -> Never {
        let message = "error: refusing to launch untagged cmux DEV; start with ./scripts/reload.sh --tag <name> (or set CMUX_TAG for test harnesses)"
        fputs("\(message)\n", stderr)
        fflush(stderr)
        NSLog("%@", message)
        Darwin.exit(64)
    }

    private static func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let ghosttyAppResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let bundledGhosttyURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty")
        var resolvedResourcesDir: String?

        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            if let bundledGhosttyURL,
               fileManager.fileExists(atPath: bundledGhosttyURL.path),
               fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            } else if fileManager.fileExists(atPath: ghosttyAppResources) {
                resolvedResourcesDir = ghosttyAppResources
            } else if let bundledGhosttyURL, fileManager.fileExists(atPath: bundledGhosttyURL.path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            }

            if let resolvedResourcesDir {
                setenv("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir, 1)
            }
        }

        if getenv("TERM") == nil {
            setenv("TERM", TerminalSurface.managedTerminalType, 1)
        }

        if getenv("COLORTERM") == nil {
            setenv("COLORTERM", TerminalSurface.managedColorTerm, 1)
        }

        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", TerminalSurface.managedTerminalProgram, 1)
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap({ String(cString: $0) }) {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            let resourcesParent = resourcesURL.deletingLastPathComponent()
            let dataDir = resourcesParent.path
            let manDir = resourcesParent.appendingPathComponent("man").path

            appendEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: dataDir,
                defaultValue: "/usr/local/share:/usr/share"
            )
            appendEnvPathIfMissing("MANPATH", path: manDir)
        }
    }

    private static func appendEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        if path.isEmpty { return }
        var current = getenv(key).flatMap { String(cString: $0) } ?? ""
        if current.isEmpty, let defaultValue {
            current = defaultValue
        }
        if current.split(separator: ":").contains(Substring(path)) {
            return
        }
        let updated = current.isEmpty ? path : "\(current):\(path)"
        setenv(key, updated, 1)
    }

    private func migrateSidebarAppearanceDefaultsIfNeeded(defaults: UserDefaults) {
        let migrationKey = "sidebarAppearanceDefaultsVersion"
        let targetVersion = 1
        guard defaults.integer(forKey: migrationKey) < targetVersion else { return }

        func normalizeHex(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "#", with: "")
                .uppercased()
        }

        func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
            abs(lhs - rhs) <= tolerance
        }

        let material = defaults.string(forKey: "sidebarMaterial") ?? SidebarMaterialOption.sidebar.rawValue
        let blendMode = defaults.string(forKey: "sidebarBlendMode") ?? SidebarBlendModeOption.behindWindow.rawValue
        let state = defaults.string(forKey: "sidebarState") ?? SidebarStateOption.followWindow.rawValue
        let tintHex = defaults.string(forKey: "sidebarTintHex") ?? "#101010"
        let tintOpacity = defaults.object(forKey: "sidebarTintOpacity") as? Double ?? 0.54
        let blurOpacity = defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? 0.79
        let cornerRadius = defaults.object(forKey: "sidebarCornerRadius") as? Double ?? 0.0

        let usesLegacyDefaults =
            material == SidebarMaterialOption.sidebar.rawValue &&
            blendMode == SidebarBlendModeOption.behindWindow.rawValue &&
            state == SidebarStateOption.followWindow.rawValue &&
            normalizeHex(tintHex) == "101010" &&
            approximatelyEqual(tintOpacity, 0.54) &&
            approximatelyEqual(blurOpacity, 0.79) &&
            approximatelyEqual(cornerRadius, 0.0)

        if usesLegacyDefaults {
            let preset = SidebarPresetOption.nativeSidebar
            defaults.set(preset.rawValue, forKey: "sidebarPreset")
            defaults.set(preset.material.rawValue, forKey: "sidebarMaterial")
            defaults.set(preset.blendMode.rawValue, forKey: "sidebarBlendMode")
            defaults.set(preset.state.rawValue, forKey: "sidebarState")
            defaults.set(preset.tintHex, forKey: "sidebarTintHex")
            defaults.set(preset.tintOpacity, forKey: "sidebarTintOpacity")
            defaults.set(preset.blurOpacity, forKey: "sidebarBlurOpacity")
            defaults.set(preset.cornerRadius, forKey: "sidebarCornerRadius")
        }

        defaults.set(targetVersion, forKey: migrationKey)
    }

    var body: some Scene {
        WindowGroup {
            MainWindowBootstrapView()
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
                        UpdateLogStore.shared.append("ui test: cmuxApp onAppear")
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
                    GhosttyApp.shared.reloadConfiguration(source: "menu.reload_configuration")
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

                Button(
                    String(
                        localized: "debug.menu.openAgentGuiReact",
                        defaultValue: "Open Agent GUI (React)"
                    )
                ) {
                    appDelegate.openDebugAgentSessionReact(nil)
                }

                Button(
                    String(
                        localized: "debug.menu.openAgentGuiSolid",
                        defaultValue: "Open Agent GUI (Solid)"
                    )
                ) {
                    appDelegate.openDebugAgentSessionSolid(nil)
                }

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
                }
            }

            windowAndViewCommands
        }

        Window(String(localized: "settings.title", defaultValue: "Settings"), id: SettingsWindowPresenter.windowID) {
            SettingsWindowRootView()
                .cmuxAppearanceColorScheme(appearanceMode)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
        }

        Window(String(localized: "settings.config.windowTitle", defaultValue: "Config"), id: ConfigSettingsView.windowID) {
            ConfigSettingsView()
                .cmuxAppearanceColorScheme(appearanceMode)
        }
    }

    @CommandsBuilder
    private var windowAndViewCommands: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button(String(localized: "menu.window.taskManager", defaultValue: "Task Manager...")) {
                TaskManagerWindowController.shared.show()
            }
        }
        helpCommands
        historyCommands
        CommandGroup(after: .toolbar) {
            splitCommandButton(title: String(localized: "menu.view.toggleLeftSidebar", defaultValue: "Toggle Left Sidebar"), shortcut: menuShortcut(for: .toggleSidebar)) {
                if AppDelegate.shared?.toggleSidebarInActiveMainWindow() != true {
                    sidebarState.toggle()
                }
            }

            splitCommandButton(title: String(localized: "menu.view.toggleRightSidebar", defaultValue: "Toggle Right Sidebar"), shortcut: menuShortcut(for: .toggleRightSidebar)) {
                if AppDelegate.shared?.toggleRightSidebarInActiveMainWindow(
                    preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                ) != true {
                    NSSound.beep()
                }
            }

            splitCommandButton(title: String(localized: "menu.view.focusRightSidebar", defaultValue: "Toggle Right Sidebar Focus"), shortcut: menuShortcut(for: .focusRightSidebar)) {
                if AppDelegate.shared?.toggleRightSidebarKeyboardFocusInActiveMainWindow() != true {
                    if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                        preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                    ) != true {
                        NSSound.beep()
                    }
                }
            }
            Divider()
            splitCommandButton(title: String(localized: "menu.view.nextSurface", defaultValue: "Next Surface"), shortcut: menuShortcut(for: .nextSurface)) {
                activeTabManager.selectNextSurface()
            }
            splitCommandButton(title: String(localized: "menu.view.previousSurface", defaultValue: "Previous Surface"), shortcut: menuShortcut(for: .prevSurface)) {
                activeTabManager.selectPreviousSurface()
            }

            splitCommandButton(title: String(localized: "menu.view.back", defaultValue: "Back"), shortcut: menuShortcut(for: .browserBack)) {
                activeTabManager.focusedBrowserPanel?.goBack()
            }

            splitCommandButton(title: String(localized: "menu.view.forward", defaultValue: "Forward"), shortcut: menuShortcut(for: .browserForward)) {
                activeTabManager.focusedBrowserPanel?.goForward()
            }

            splitCommandButton(title: String(localized: "menu.view.reloadPage", defaultValue: "Reload Page"), shortcut: menuShortcut(for: .browserReload)) {
                activeTabManager.focusedBrowserPanel?.reload()
            }

            splitCommandButton(title: String(localized: "menu.view.toggleDevTools", defaultValue: "Toggle Developer Tools"), shortcut: menuShortcut(for: .toggleBrowserDeveloperTools)) {
                let manager = activeTabManager
                if !manager.toggleDeveloperToolsFocusedBrowser() {
                    NSSound.beep()
                }
            }

            splitCommandButton(title: String(localized: "menu.view.showJSConsole", defaultValue: "Show JavaScript Console"), shortcut: menuShortcut(for: .showBrowserJavaScriptConsole)) {
                let manager = activeTabManager
                if !manager.showJavaScriptConsoleFocusedBrowser() {
                    NSSound.beep()
                }
            }

            splitCommandButton(title: String(localized: "menu.view.toggleReactGrab", defaultValue: "Toggle React Grab"), shortcut: menuShortcut(for: .toggleReactGrab)) {
                if !activeTabManager.toggleReactGrabFromCurrentFocus() {
                    NSSound.beep()
                }
            }

            splitCommandButton(title: String(localized: "menu.view.zoomIn", defaultValue: "Zoom In"), shortcut: menuShortcut(for: .browserZoomIn)) {
                _ = activeTabManager.zoomInFocusedBrowser()
            }

            splitCommandButton(title: String(localized: "menu.view.zoomOut", defaultValue: "Zoom Out"), shortcut: menuShortcut(for: .browserZoomOut)) {
                _ = activeTabManager.zoomOutFocusedBrowser()
            }

            splitCommandButton(title: String(localized: "menu.view.actualSize", defaultValue: "Actual Size"), shortcut: menuShortcut(for: .browserZoomReset)) {
                _ = activeTabManager.resetZoomFocusedBrowser()
            }

            Button(String(localized: "menu.view.clearBrowserHistory", defaultValue: "Clear Browser History")) {
                BrowserHistoryStore.shared.clearHistory()
            }

            Button(String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…")) {
                // Defer modal presentation until after AppKit finishes menu tracking.
                DispatchQueue.main.async {
                    BrowserDataImportCoordinator.shared.presentImportDialog()
                }
            }

            splitCommandButton(title: String(localized: "menu.view.nextWorkspace", defaultValue: "Next Workspace"), shortcut: menuShortcut(for: .nextSidebarTab)) {
                activeTabManager.selectNextTab()
            }

            splitCommandButton(title: String(localized: "menu.view.previousWorkspace", defaultValue: "Previous Workspace"), shortcut: menuShortcut(for: .prevSidebarTab)) {
                activeTabManager.selectPreviousTab()
            }

            splitCommandButton(title: String(localized: "menu.view.renameWorkspace", defaultValue: "Rename Workspace…"), shortcut: menuShortcut(for: .renameWorkspace)) {
                _ = AppDelegate.shared?.requestRenameWorkspaceViaCommandPalette()
            }

            splitCommandButton(title: String(localized: "menu.view.editWorkspaceDescription", defaultValue: "Edit Workspace Description…"), shortcut: menuShortcut(for: .editWorkspaceDescription)) {
                _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
            }

            splitCommandButton(title: String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen"), shortcut: menuShortcut(for: .toggleFullScreen)) {
                guard let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }
                targetWindow.toggleFullScreen(nil)
            }

            Divider()

            splitCommandButton(title: String(localized: "menu.view.splitRight", defaultValue: "Split Right"), shortcut: menuShortcut(for: .splitRight)) {
                performSplitFromMenu(direction: .right)
            }

            splitCommandButton(title: String(localized: "menu.view.splitDown", defaultValue: "Split Down"), shortcut: menuShortcut(for: .splitDown)) {
                performSplitFromMenu(direction: .down)
            }

            splitCommandButton(title: String(localized: "menu.view.splitBrowserRight", defaultValue: "Split Browser Right"), shortcut: menuShortcut(for: .splitBrowserRight)) {
                performBrowserSplitFromMenu(direction: .right)
            }

            splitCommandButton(title: String(localized: "menu.view.splitBrowserDown", defaultValue: "Split Browser Down"), shortcut: menuShortcut(for: .splitBrowserDown)) {
                performBrowserSplitFromMenu(direction: .down)
            }

            equalizeSplitsCommandButton()
            Divider()

            // Numbered workspace selection (9 = last workspace)
            ForEach(1...9, id: \.self) { number in
                let selectWorkspaceByNumberShortcut = menuShortcut(for: .selectWorkspaceByNumber)
                if selectWorkspaceByNumberShortcut.isUnbound || selectWorkspaceByNumberShortcut.hasChord {
                    Button(String(localized: "menu.view.workspace", defaultValue: "Workspace \(number)")) {
                        let manager = activeTabManager
                        if let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: number, workspaceCount: manager.tabs.count) {
                            manager.selectTab(at: targetIndex)
                        }
                    }
                } else {
                    Button(String(localized: "menu.view.workspace", defaultValue: "Workspace \(number)")) {
                        let manager = activeTabManager
                        if let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: number, workspaceCount: manager.tabs.count) {
                            manager.selectTab(at: targetIndex)
                        }
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(number)")),
                        modifiers: selectWorkspaceByNumberShortcut.eventModifiers
                    )
                }
            }

            Divider()

            splitCommandButton(title: String(localized: "menu.view.jumpToUnread", defaultValue: "Jump to Latest Unread"), shortcut: menuShortcut(for: .jumpToUnread)) {
                AppDelegate.shared?.jumpToLatestUnread()
            }

            splitCommandButton(title: String(localized: "menu.view.showNotifications", defaultValue: "Show Notifications"), shortcut: menuShortcut(for: .showNotifications)) {
                showNotificationsPopover()
            }
        }
    }

    private func showAboutPanel() {
        AboutWindowController.shared.show()
    }

    private func applyAppearance() {
        let mode = AppearanceSettings.applyStoredMode(
            rawValue: appearanceMode,
            source: "cmuxApp.appearanceModeChanged"
        )
        if appearanceMode != mode.rawValue {
            appearanceMode = mode.rawValue
        }
    }

    private static func applyAppearance(_ mode: AppearanceMode, duringLaunch: Bool = false) {
        AppearanceSettings.applyLiveMode(
            mode,
            source: duringLaunch ? "cmuxApp.launch" : "cmuxApp.applyAppearance",
            duringLaunch: duringLaunch,
            synchronizeTerminalTheme: !duringLaunch
        )
    }

    private func updateSocketController() {
        let mode = SocketControlSettings.effectiveMode(userMode: currentSocketMode)
        if mode != .off {
            let socketPath = TerminalController.shared.activeSocketPath(
                preferredPath: SocketControlSettings.socketPath()
            )
            TerminalController.shared.start(
                tabManager: activeTabManager,
                socketPath: socketPath,
                accessMode: mode
            )
        } else {
            TerminalController.shared.stop()
        }
    }

    private func bootstrapMainWindowScene() {
        appDelegate.scheduleInitialMainWindowBootstrap(debugSource: "swiftUIBootstrap")
        applyAppearance()
    }

    private var currentSocketMode: SocketControlMode {
        SocketControlSettings.migrateMode(socketControlMode)
    }

    func menuShortcut(for action: KeyboardShortcutSettings.Action) -> StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.menuShortcut(for: action)
    }

    private var notificationMenuSnapshot: NotificationMenuSnapshot {
        notificationStore.notificationMenuSnapshot
    }

    var activeTabManager: TabManager {
        AppDelegate.shared?.activeTabManagerForCommands(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        ) ?? tabManager
    }

    private func notificationMenuItemTitle(for notification: TerminalNotification) -> String {
        let tabTitle = appDelegate.tabTitle(for: notification.tabId)
        return MenuBarNotificationLineFormatter.menuTitle(notification: notification, tabTitle: tabTitle)
    }

    private func openNotificationFromMainMenu(_ notification: TerminalNotification) {
        _ = appDelegate.openTerminalNotification(notification)
    }

    private func performSplitFromMenu(direction: SplitDirection) {
        if AppDelegate.shared?.performSplitShortcut(direction: direction) == true {
            return
        }
        tabManager.createSplit(direction: direction)
    }

    private func performBrowserSplitFromMenu(direction: SplitDirection) {
        if AppDelegate.shared?.performBrowserSplitShortcut(direction: direction) == true {
            return
        }
        _ = tabManager.createBrowserSplit(direction: direction)
    }

    private func selectedWorkspaceIndex(in manager: TabManager, workspaceId: UUID) -> Int? {
        manager.tabs.firstIndex { $0.id == workspaceId }
    }

    private func selectedWorkspaceWindowMoveTargets(in manager: TabManager) -> [AppDelegate.WindowMoveTarget] {
        let referenceWindowId = AppDelegate.shared?.windowId(for: manager)
        return AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
    }

    private func toggleSelectedWorkspacePinned(in manager: TabManager) {
        if !WorkspacePinCommands.toggleSelectedWorkspace(in: manager) {
            NSSound.beep()
        }
    }

    private func clearSelectedWorkspaceCustomName(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.clearCustomTitle(tabId: workspace.id)
    }

    private func moveSelectedWorkspace(in manager: TabManager, by delta: Int) {
        guard let workspace = manager.selectedWorkspace,
              let currentIndex = selectedWorkspaceIndex(in: manager, workspaceId: workspace.id) else { return }
        let targetIndex = currentIndex + delta
        guard targetIndex >= 0, targetIndex < manager.tabs.count else { return }
        _ = manager.reorderWorkspace(tabId: workspace.id, toIndex: targetIndex)
        manager.selectWorkspace(workspace)
    }

    private func moveSelectedWorkspaceToTop(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        manager.moveTabsToTop([workspace.id])
        manager.selectWorkspace(workspace)
    }

    private func moveSelectedWorkspace(in manager: TabManager, toWindow windowId: UUID) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToWindow(workspaceId: workspace.id, windowId: windowId, focus: true)
    }

    private func moveSelectedWorkspaceToNewWindow(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        _ = AppDelegate.shared?.moveWorkspaceToNewWindow(workspaceId: workspace.id, focus: true)
    }

    private func closeWorkspaceIds(
        _ workspaceIds: [UUID],
        in manager: TabManager,
        allowPinned: Bool
    ) {
        manager.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: allowPinned)
    }

    private func closeOtherSelectedWorkspacePeers(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace else { return }
        let workspaceIds = manager.tabs.compactMap { $0.id == workspace.id ? nil : $0.id }
        closeWorkspaceIds(workspaceIds, in: manager, allowPinned: true)
    }

    private func closeSelectedWorkspacesBelow(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace,
              let anchorIndex = selectedWorkspaceIndex(in: manager, workspaceId: workspace.id) else { return }
        let workspaceIds = manager.tabs.suffix(from: anchorIndex + 1).map(\.id)
        closeWorkspaceIds(workspaceIds, in: manager, allowPinned: true)
    }

    private func closeSelectedWorkspacesAbove(in manager: TabManager) {
        guard let workspace = manager.selectedWorkspace,
              let anchorIndex = selectedWorkspaceIndex(in: manager, workspaceId: workspace.id) else { return }
        let workspaceIds = manager.tabs.prefix(upTo: anchorIndex).map(\.id)
        closeWorkspaceIds(workspaceIds, in: manager, allowPinned: true)
    }

    private func selectedWorkspaceCanMarkRead(in manager: TabManager) -> Bool {
        guard let workspaceId = manager.selectedWorkspace?.id else { return false }
        return notificationStore.canMarkWorkspaceRead(forTabIds: [workspaceId])
    }

    private func selectedWorkspaceCanMarkUnread(in manager: TabManager) -> Bool {
        guard let workspaceId = manager.selectedWorkspace?.id else { return false }
        return notificationStore.canMarkWorkspaceUnread(forTabIds: [workspaceId])
    }

    private func markSelectedWorkspaceRead(in manager: TabManager) {
        guard let workspaceId = manager.selectedWorkspace?.id else { return }
        notificationStore.markRead(forTabId: workspaceId)
    }

    private func markSelectedWorkspaceUnread(in manager: TabManager) {
        guard let workspaceId = manager.selectedWorkspace?.id else { return }
        notificationStore.markUnread(forTabId: workspaceId)
    }

    @ViewBuilder
    private func workspaceCommandMenuContent(manager: TabManager) -> some View {
        let workspace = manager.selectedWorkspace
        let workspaceIndex = workspace.flatMap { selectedWorkspaceIndex(in: manager, workspaceId: $0.id) }
        let windowMoveTargets = selectedWorkspaceWindowMoveTargets(in: manager)
        let pinState = WorkspacePinCommands.selectedWorkspacePinState(in: manager)

        Button(WorkspacePinCommands.selectedWorkspaceMenuLabel(in: manager, pinState: pinState)) {
            toggleSelectedWorkspacePinned(in: manager)
        }
        .disabled(pinState == nil)

        Button(String(localized: "menu.view.renameWorkspace", defaultValue: "Rename Workspace…")) {
            _ = AppDelegate.shared?.requestRenameWorkspaceViaCommandPalette()
        }
        .disabled(workspace == nil)

        Button(String(localized: "menu.view.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
            _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
        }
        .disabled(workspace == nil)

        if workspace?.hasCustomTitle == true {
            Button(String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")) {
                clearSelectedWorkspaceCustomName(in: manager)
            }
        }

        Divider()

        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveSelectedWorkspace(in: manager, by: -1)
        }
        .disabled(workspaceIndex == nil || workspaceIndex == 0)

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveSelectedWorkspace(in: manager, by: 1)
        }
        .disabled(workspaceIndex == nil || workspaceIndex == manager.tabs.count - 1)

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")) {
            moveSelectedWorkspaceToTop(in: manager)
        }
        .disabled(workspace == nil || workspaceIndex == 0)

        Menu(String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                moveSelectedWorkspaceToNewWindow(in: manager)
            }
            .disabled(workspace == nil)

            if !windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(windowMoveTargets) { target in
                Button(target.label) {
                    moveSelectedWorkspace(in: manager, toWindow: target.windowId)
                }
                .disabled(target.isCurrentWindow || workspace == nil)
            }
        }
        .disabled(workspace == nil)

        Divider()

        Button(String(localized: "menu.file.closeWorkspace", defaultValue: "Close Workspace")) {
            manager.closeCurrentWorkspaceWithConfirmation()
        }
        .disabled(workspace == nil)

        Button(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")) {
            closeOtherSelectedWorkspacePeers(in: manager)
        }
        .disabled(workspace == nil || manager.tabs.count <= 1)

        Button(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")) {
            closeSelectedWorkspacesBelow(in: manager)
        }
        .disabled(workspaceIndex == nil || workspaceIndex == manager.tabs.count - 1)

        Button(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")) {
            closeSelectedWorkspacesAbove(in: manager)
        }
        .disabled(workspaceIndex == nil || workspaceIndex == 0)

        Divider()

        Button(String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read")) {
            markSelectedWorkspaceRead(in: manager)
        }
        .disabled(!selectedWorkspaceCanMarkRead(in: manager))

        Button(String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")) {
            markSelectedWorkspaceUnread(in: manager)
        }
        .disabled(!selectedWorkspaceCanMarkUnread(in: manager))
    }

    @ViewBuilder
    func splitCommandButton(title: String, shortcut: StoredShortcut, action: @escaping () -> Void) -> some View {
        if let key = shortcut.keyEquivalent {
            Button(title, action: action)
                .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(title, action: action)
        }
    }

    private func closePanelOrWindow() {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           cmuxWindowShouldOwnCloseShortcut(window) {
            window.performClose(nil)
            return
        }
        activeTabManager.closeCurrentPanelWithConfirmation()
    }

    private func closeOtherTabsInFocusedPane() {
        activeTabManager.closeOtherTabsInFocusedPaneWithConfirmation()
    }

    private func closeTabOrWindow() {
        activeTabManager.closeCurrentTabWithConfirmation()
    }

    private func showNotificationsPopover() {
        AppDelegate.shared?.toggleNotificationsPopover(animated: false)
    }

#if DEBUG
    private func openAllDebugWindows() {
        DebugWindowControlsWindowController.shared.show()
        BrowserImportHintDebugWindowController.shared.show()
        BrowserProfilePopoverDebugWindowController.shared.show()
        AboutTitlebarDebugWindowController.shared.show()
        TitlebarLayoutDebugWindowController.shared.show()
        SidebarDebugWindowController.shared.show()
        BackgroundDebugWindowController.shared.show()
        StartupAppearanceDebugWindowController.shared.show()
        MenuBarExtraDebugWindowController.shared.show()
        PDFPreviewChromeDebugWindowController.shared.show()
        FeedPreviewWindowController.shared.show()
        FeedTextEditorDebugWindowController.shared.show()
        FeedButtonStyleDebugWindowController.shared.show()
        BonsplitTabBarDebugWindowController.shared.show()
    }
#endif
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


private let cmuxAuxiliaryWindowIdentifiers: Set<String> = [
    "cmux.settings",
    "cmux.about",
    "cmux.licenses",
    "cmux.browser-popup",
    "cmux.browserProfilePopoverDebug",
    "cmux.configEditor",
    "cmux.feedButtonStyleDebug",
    "cmux.feedPreview",
    "cmux.feedTextEditorDebug",
    "cmux.fileExplorerStyleDebug",
    "cmux.folderDragIcon",
    "cmux.pdfPreviewChromeDebug",
    "cmux.recentlyClosedHistory",
    "cmux.splitButtonLayoutDebug",
    "cmux.tabBarBackdropLab",
    "cmux.taskManager",
    "cmux.aboutTitlebarDebug",
    "cmux.debugWindowControls",
    "cmux.browserImportHintDebug",
    "cmux.extensionSidebarInspector",
    "cmux.sidebarDebug",
    "cmux.menubarDebug",
    "cmux.backgroundDebug",
    "cmux.startupAppearanceDebug",
    "cmux.bonsplitTabBarDebug",
    "cmux.titlebarLayoutDebug",
]

/// Returns whether the given window should handle the standard close shortcut
/// as a standalone auxiliary window instead of routing it through workspace or
/// panel-close behavior.
func cmuxWindowShouldOwnCloseShortcut(_ window: NSWindow?) -> Bool {
    guard let identifier = window?.identifier?.rawValue else { return false }
    return cmuxAuxiliaryWindowIdentifiers.contains(identifier)
}

private enum AboutWindowKind: String, CaseIterable, Identifiable {
    case about

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .about:
            return "About Window"
        }
    }

    var windowIdentifier: String {
        switch self {
        case .about:
            return "cmux.about"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .about:
            return "About cmux"
        }
    }

    var minimumSize: NSSize {
        switch self {
        case .about:
            return NSSize(width: 360, height: 520)
        }
    }
}

private enum TitlebarVisibilityOption: String, CaseIterable, Identifiable {
    case hidden
    case visible

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .visible:
            return "Visible"
        }
    }

    var windowValue: NSWindow.TitleVisibility {
        switch self {
        case .hidden:
            return .hidden
        case .visible:
            return .visible
        }
    }
}

private enum TitlebarToolbarStyleOption: String, CaseIterable, Identifiable {
    case automatic
    case expanded
    case preference
    case unified
    case unifiedCompact

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .expanded:
            return "Expanded"
        case .preference:
            return "Preference"
        case .unified:
            return "Unified"
        case .unifiedCompact:
            return "Unified Compact"
        }
    }

    var windowValue: NSWindow.ToolbarStyle {
        switch self {
        case .automatic:
            return .automatic
        case .expanded:
            return .expanded
        case .preference:
            return .preference
        case .unified:
            return .unified
        case .unifiedCompact:
            return .unifiedCompact
        }
    }
}

private struct AboutTitlebarDebugOptions: Equatable {
    var overridesEnabled: Bool
    var windowTitle: String
    var titleVisibility: TitlebarVisibilityOption
    var titlebarAppearsTransparent: Bool
    var movableByWindowBackground: Bool
    var titled: Bool
    var closable: Bool
    var miniaturizable: Bool
    var resizable: Bool
    var fullSizeContentView: Bool
    var showToolbar: Bool
    var toolbarStyle: TitlebarToolbarStyleOption

    static func defaults(for kind: AboutWindowKind) -> AboutTitlebarDebugOptions {
        switch kind {
        case .about:
            return AboutTitlebarDebugOptions(
                overridesEnabled: false,
                windowTitle: "About cmux",
                titleVisibility: .hidden,
                titlebarAppearsTransparent: true,
                movableByWindowBackground: false,
                titled: true,
                closable: true,
                miniaturizable: true,
                resizable: false,
                fullSizeContentView: false,
                showToolbar: false,
                toolbarStyle: .automatic
            )
        }
    }
}

@MainActor
private final class AboutTitlebarDebugStore: ObservableObject {
    static let shared = AboutTitlebarDebugStore()

    @Published var aboutOptions = AboutTitlebarDebugOptions.defaults(for: .about) {
        didSet { applyToOpenWindows(for: .about) }
    }

    private init() {}

    func options(for kind: AboutWindowKind) -> AboutTitlebarDebugOptions {
        switch kind {
        case .about:
            return aboutOptions
        }
    }

    func update(_ newValue: AboutTitlebarDebugOptions, for kind: AboutWindowKind) {
        switch kind {
        case .about:
            aboutOptions = newValue
        }
    }

    func reset(_ kind: AboutWindowKind) {
        update(AboutTitlebarDebugOptions.defaults(for: kind), for: kind)
    }

    func applyToOpenWindows(for kind: AboutWindowKind) {
        for window in NSApp.windows where window.identifier?.rawValue == kind.windowIdentifier {
            apply(options(for: kind), to: window, for: kind)
        }
    }

    func applyToOpenWindows() {
        applyToOpenWindows(for: .about)
    }

    func applyCurrentOptions(to window: NSWindow, for kind: AboutWindowKind) {
        apply(options(for: kind), to: window, for: kind)
    }

    func copyConfigToPasteboard() {
        let about = options(for: .about)
        let payload = """
        # About Titlebar Debug
        about.overridesEnabled=\(about.overridesEnabled)
        about.title=\(about.windowTitle)
        about.titleVisibility=\(about.titleVisibility.rawValue)
        about.titlebarAppearsTransparent=\(about.titlebarAppearsTransparent)
        about.movableByWindowBackground=\(about.movableByWindowBackground)
        about.titled=\(about.titled)
        about.closable=\(about.closable)
        about.miniaturizable=\(about.miniaturizable)
        about.resizable=\(about.resizable)
        about.fullSizeContentView=\(about.fullSizeContentView)
        about.showToolbar=\(about.showToolbar)
        about.toolbarStyle=\(about.toolbarStyle.rawValue)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    private func apply(_ options: AboutTitlebarDebugOptions, to window: NSWindow, for kind: AboutWindowKind) {
        let effective = options.overridesEnabled ? options : AboutTitlebarDebugOptions.defaults(for: kind)
        let resolvedTitle = effective.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = resolvedTitle.isEmpty ? kind.fallbackTitle : resolvedTitle
        window.titleVisibility = effective.titleVisibility.windowValue
        window.titlebarAppearsTransparent = effective.titlebarAppearsTransparent
        window.isMovableByWindowBackground = effective.movableByWindowBackground
        window.toolbarStyle = effective.toolbarStyle.windowValue

        if effective.showToolbar {
            ensureToolbar(on: window, kind: kind)
        } else if window.toolbar != nil {
            window.toolbar = nil
        }

        var styleMask = window.styleMask
        setStyleMaskBit(&styleMask, .titled, enabled: effective.titled)
        setStyleMaskBit(&styleMask, .closable, enabled: effective.closable)
        setStyleMaskBit(&styleMask, .miniaturizable, enabled: effective.miniaturizable)
        setStyleMaskBit(&styleMask, .resizable, enabled: effective.resizable)
        setStyleMaskBit(&styleMask, .fullSizeContentView, enabled: effective.fullSizeContentView)
        window.styleMask = styleMask

        let maxSize = effective.resizable ? NSSize(width: 8192, height: 8192) : kind.minimumSize
        window.minSize = kind.minimumSize
        window.maxSize = maxSize
        window.contentMinSize = kind.minimumSize
        window.contentMaxSize = maxSize
        window.invalidateShadow()
        AppDelegate.shared?.applyWindowDecorations(to: window)
    }

    private func ensureToolbar(on window: NSWindow, kind: AboutWindowKind) {
        guard window.toolbar == nil else { return }
        let identifier = NSToolbar.Identifier("cmux.debug.titlebar.\(kind.rawValue)")
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
    }

    private func setStyleMaskBit(
        _ styleMask: inout NSWindow.StyleMask,
        _ bit: NSWindow.StyleMask,
        enabled: Bool
    ) {
        if enabled {
            styleMask.insert(bit)
        } else {
            styleMask.remove(bit)
        }
    }
}

private final class AboutTitlebarDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutTitlebarDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 690),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.aboutTitlebarDebug.title",
            defaultValue: "About Titlebar Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.aboutTitlebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: AboutTitlebarDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        AboutTitlebarDebugStore.shared.applyToOpenWindows()
    }
}

private struct AboutTitlebarDebugView: View {
    @ObservedObject private var store = AboutTitlebarDebugStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "debug.aboutTitlebarDebug.title", defaultValue: "About Titlebar Debug"))
                    .font(.headline)

                editor(for: .about)

                GroupBox("Actions") {
                    HStack(spacing: 10) {
                        Button("Reset All") {
                            store.reset(.about)
                        }
                        Button("Reapply to Open Windows") {
                            store.applyToOpenWindows()
                        }
                        Button("Copy Config") {
                            store.copyConfigToPasteboard()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func editor(for kind: AboutWindowKind) -> some View {
        let overridesEnabled = binding(for: kind, keyPath: \.overridesEnabled)

        return GroupBox(kind.displayTitle) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Debug Overrides", isOn: overridesEnabled)

                Text("When disabled, cmux uses normal default titlebar behavior for this window.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Window Title")
                        TextField("", text: binding(for: kind, keyPath: \.windowTitle))
                    }

                    HStack(spacing: 10) {
                        Picker("Title Visibility", selection: binding(for: kind, keyPath: \.titleVisibility)) {
                            ForEach(TitlebarVisibilityOption.allCases) { option in
                                Text(option.displayTitle).tag(option)
                            }
                        }
                        Picker("Toolbar Style", selection: binding(for: kind, keyPath: \.toolbarStyle)) {
                            ForEach(TitlebarToolbarStyleOption.allCases) { option in
                                Text(option.displayTitle).tag(option)
                            }
                        }
                    }

                    Toggle("Show Toolbar", isOn: binding(for: kind, keyPath: \.showToolbar))
                    Toggle("Transparent Titlebar", isOn: binding(for: kind, keyPath: \.titlebarAppearsTransparent))
                    Toggle("Movable by Window Background", isOn: binding(for: kind, keyPath: \.movableByWindowBackground))

                    Divider()

                    Text("Style Mask")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Titled", isOn: binding(for: kind, keyPath: \.titled))
                    Toggle("Closable", isOn: binding(for: kind, keyPath: \.closable))
                    Toggle("Miniaturizable", isOn: binding(for: kind, keyPath: \.miniaturizable))
                    Toggle("Resizable", isOn: binding(for: kind, keyPath: \.resizable))
                    Toggle("Full Size Content View", isOn: binding(for: kind, keyPath: \.fullSizeContentView))

                    HStack(spacing: 10) {
                        Button(String(localized: "debug.aboutTitlebarDebug.resetAbout", defaultValue: "Reset About")) {
                            store.reset(kind)
                        }
                        Button("Apply Now") {
                            store.applyToOpenWindows(for: kind)
                        }
                    }
                }
                .disabled(!overridesEnabled.wrappedValue)
                .opacity(overridesEnabled.wrappedValue ? 1 : 0.75)
            }
            .padding(.top, 2)
        }
    }

    private func binding<Value>(
        for kind: AboutWindowKind,
        keyPath: WritableKeyPath<AboutTitlebarDebugOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.options(for: kind)[keyPath: keyPath] },
            set: { newValue in
                var updated = store.options(for: kind)
                updated[keyPath: keyPath] = newValue
                store.update(updated, for: kind)
            }
        )
    }
}

private enum DebugWindowConfigSnapshot {
    static func copyCombinedToPasteboard(defaults: UserDefaults = .standard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(combinedPayload(defaults: defaults), forType: .string)
    }

    static func combinedPayload(defaults: UserDefaults = .standard) -> String {
        let sidebarPayload = """
        sidebarPreset=\(stringValue(defaults, key: "sidebarPreset", fallback: SidebarPresetOption.nativeSidebar.rawValue))
        sidebarMaterial=\(stringValue(defaults, key: "sidebarMaterial", fallback: SidebarMaterialOption.sidebar.rawValue))
        sidebarBlendMode=\(stringValue(defaults, key: "sidebarBlendMode", fallback: SidebarBlendModeOption.withinWindow.rawValue))
        sidebarState=\(stringValue(defaults, key: "sidebarState", fallback: SidebarStateOption.followWindow.rawValue))
        sidebarBlurOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "sidebarBlurOpacity", fallback: 1.0)))
        sidebarTintHex=\(stringValue(defaults, key: "sidebarTintHex", fallback: "#000000"))
        sidebarTintHexLight=\(stringValue(defaults, key: "sidebarTintHexLight", fallback: "(nil)"))
        sidebarTintHexDark=\(stringValue(defaults, key: "sidebarTintHexDark", fallback: "(nil)"))
        sidebarTintOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "sidebarTintOpacity", fallback: 0.18)))
        sidebarCornerRadius=\(String(format: "%.1f", doubleValue(defaults, key: "sidebarCornerRadius", fallback: 0.0)))
        sidebarBranchVerticalLayout=\(boolValue(defaults, key: SidebarBranchLayoutSettings.key, fallback: SidebarBranchLayoutSettings.defaultVerticalLayout))
        sidebarBranchDirectoryStacked=\(boolValue(defaults, key: SidebarBranchDirectoryStackedSettings.key, fallback: SidebarBranchDirectoryStackedSettings.defaultStacked))
        sidebarPathLastSegmentOnly=\(boolValue(defaults, key: SidebarPathLastSegmentSettings.key, fallback: SidebarPathLastSegmentSettings.defaultLastSegmentOnly))
        sidebarActiveTabIndicatorStyle=\(stringValue(defaults, key: SidebarActiveTabIndicatorSettings.styleKey, fallback: SidebarActiveTabIndicatorSettings.defaultStyle.rawValue))
        sidebarDevBuildBannerVisible=\(boolValue(defaults, key: DevBuildBannerDebugSettings.sidebarBannerVisibleKey, fallback: DevBuildBannerDebugSettings.defaultShowSidebarBanner))
        sidebarMinimumWidth=\(String(format: "%.1f", SessionPersistencePolicy.resolvedMinimumSidebarWidth(defaults: defaults)))
        """

        let backgroundPayload = """
        bgGlassEnabled=\(boolValue(defaults, key: "bgGlassEnabled", fallback: false))
        bgGlassMaterial=\(stringValue(defaults, key: "bgGlassMaterial", fallback: "hudWindow"))
        bgGlassTintHex=\(stringValue(defaults, key: "bgGlassTintHex", fallback: "#000000"))
        bgGlassTintOpacity=\(String(format: "%.2f", doubleValue(defaults, key: "bgGlassTintOpacity", fallback: 0.03)))
        """

        let menuBarPayload = MenuBarIconDebugSettings.copyPayload(defaults: defaults)
        let browserDevToolsPayload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: defaults)
        let titlebarLayoutPayload = TitlebarLayoutDebugSettingsSnapshot.copyPayload(defaults: defaults)

        return """
        # Sidebar Debug
        \(sidebarPayload)

        # Titlebar Layout Debug
        \(titlebarLayoutPayload)

        # Background Debug
        \(backgroundPayload)

        # Menu Bar Extra Debug
        \(menuBarPayload)

        # Browser DevTools Button
        \(browserDevToolsPayload)
        """
    }

    private static func stringValue(_ defaults: UserDefaults, key: String, fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private static func doubleValue(_ defaults: UserDefaults, key: String, fallback: Double) -> Double {
        if let value = defaults.object(forKey: key) as? NSNumber {
            return value.doubleValue
        }
        if let text = defaults.string(forKey: key), let parsed = Double(text) {
            return parsed
        }
        return fallback
    }

    private static func boolValue(_ defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}

#if DEBUG
private final class DebugWindowControlsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = DebugWindowControlsWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Debug Window Controls"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.debugWindowControls")
        window.center()
        window.contentView = NSHostingView(rootView: DebugWindowControlsView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DebugWindowControlsView: View {
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconNameKey) private var browserDevToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconColorKey) private var browserDevToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue

    private var selectedDevToolsIconOption: BrowserDevToolsIconOption {
        BrowserDevToolsIconOption(rawValue: browserDevToolsIconNameRaw) ?? BrowserDevToolsButtonDebugSettings.defaultIcon
    }

    private var selectedDevToolsColorOption: BrowserDevToolsIconColorOption {
        BrowserDevToolsIconColorOption(rawValue: browserDevToolsIconColorRaw) ?? BrowserDevToolsButtonDebugSettings.defaultColor
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Debug Window Controls")
                    .font(.headline)

                GroupBox("Open") {
                    VStack(alignment: .leading, spacing: 8) {
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
                                localized: "debug.menu.pdfPreviewChromeDebug",
                                defaultValue: "PDF Preview Chrome Debug…"
                            )
                        ) {
                            PDFPreviewChromeDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.tabBarBackdropLab",
                                defaultValue: "Tab Bar Backdrop Lab…"
                            )
                        ) {
                            TabBarBackdropLabWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.feedTextEditorDebug",
                                defaultValue: "Feed Text Editor Lab…"
                            )
                        ) {
                            FeedTextEditorDebugWindowController.shared.show()
                        }
                        Button("Open All Debug Windows") {
                            DebugWindowControlsWindowController.shared.show()
                            BrowserImportHintDebugWindowController.shared.show()
                            BrowserProfilePopoverDebugWindowController.shared.show()
                            AboutTitlebarDebugWindowController.shared.show()
                            TitlebarLayoutDebugWindowController.shared.show()
                            SidebarDebugWindowController.shared.show()
                            BackgroundDebugWindowController.shared.show()
                            BonsplitTabBarDebugWindowController.shared.show()
                            StartupAppearanceDebugWindowController.shared.show()
                            MenuBarExtraDebugWindowController.shared.show()
                            PDFPreviewChromeDebugWindowController.shared.show()
                            TabBarBackdropLabWindowController.shared.show()
                            FeedTextEditorDebugWindowController.shared.show()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                GroupBox("Active Workspace Indicator") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Style", selection: sidebarIndicatorStyleSelection) {
                            ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("Reset Indicator Style") {
                            sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Browser DevTools Button") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Icon")
                            Picker("Icon", selection: $browserDevToolsIconNameRaw) {
                                ForEach(BrowserDevToolsIconOption.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text("Color")
                            Picker("Color", selection: $browserDevToolsIconColorRaw) {
                                ForEach(BrowserDevToolsIconColorOption.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text("Preview")
                            Spacer()
                            Image(systemName: selectedDevToolsIconOption.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(selectedDevToolsColorOption.color)
                        }

                        HStack(spacing: 12) {
                            Button("Reset Button") {
                                resetBrowserDevToolsButton()
                            }
                            Button("Copy Button Config") {
                                copyBrowserDevToolsButtonConfig()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Copy") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Copy All Debug Config") {
                            DebugWindowConfigSnapshot.copyCombinedToPasteboard()
                        }
                        Text("Copies sidebar, background, menu bar, and browser devtools settings as one payload.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func resetBrowserDevToolsButton() {
        browserDevToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
        browserDevToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue
    }

    private func copyBrowserDevToolsButtonConfig() {
        let payload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: .standard)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
}
#endif

private final class BrowserImportHintDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BrowserImportHintDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Browser Import Hint Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserImportHintDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserImportHintDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class BrowserProfilePopoverDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BrowserProfilePopoverDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.windows.browserProfilePopover.title",
            defaultValue: "Browser Profile Popover Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserProfilePopoverDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserProfilePopoverDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BrowserProfilePopoverDebugView: View {
    @AppStorage(BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
    private var horizontalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
    @AppStorage(BrowserProfilePopoverDebugSettings.verticalPaddingKey)
    private var verticalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultVerticalPadding

    private var horizontalPaddingBinding: Binding<Double> {
        Binding(
            get: { BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding(horizontalPaddingRaw) },
            set: { horizontalPaddingRaw = BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding($0) }
        )
    }

    private var verticalPaddingBinding: Binding<Double> {
        Binding(
            get: { BrowserProfilePopoverDebugSettings.resolvedVerticalPadding(verticalPaddingRaw) },
            set: { verticalPaddingRaw = BrowserProfilePopoverDebugSettings.resolvedVerticalPadding($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    String(
                        localized: "debug.browserProfilePopover.heading",
                        defaultValue: "Browser Profile Popover"
                    )
                )
                .font(.headline)

                Text(
                    String(
                        localized: "debug.browserProfilePopover.note",
                        defaultValue: "Tune the profile popover padding live while comparing it against the browser toolbar menu."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                GroupBox(
                    String(
                        localized: "debug.browserProfilePopover.group.padding",
                        defaultValue: "Padding"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow(
                            String(
                                localized: "debug.browserProfilePopover.label.horizontal",
                                defaultValue: "Horizontal"
                            ),
                            value: horizontalPaddingBinding,
                            range: BrowserProfilePopoverDebugSettings.horizontalPaddingRange
                        )
                        sliderRow(
                            String(
                                localized: "debug.browserProfilePopover.label.vertical",
                                defaultValue: "Vertical"
                            ),
                            value: verticalPaddingBinding,
                            range: BrowserProfilePopoverDebugSettings.verticalPaddingRange
                        )
                    }
                    .padding(.top, 2)
                }

                GroupBox(
                    String(
                        localized: "debug.browserProfilePopover.group.preview",
                        defaultValue: "Preview"
                    )
                ) {
                    profilePopoverPreview
                        .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button(
                        String(
                            localized: "debug.browserProfilePopover.reset",
                            defaultValue: "Reset"
                        )
                    ) {
                        horizontalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
                        verticalPaddingRaw = BrowserProfilePopoverDebugSettings.defaultVerticalPadding
                    }
                }

                Text(
                    String(
                        localized: "debug.browserProfilePopover.liveNote",
                        defaultValue: "Changes apply live to the browser profile popover."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var profilePopoverPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.profile.menu.title", defaultValue: "Profiles"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, alignment: .center)
                    Text(String(localized: "browser.profile.default", defaultValue: "Default"))
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                )
            }

            Divider()

            Text(String(localized: "browser.profile.new", defaultValue: "New Profile..."))
                .font(.system(size: 12))

            Text(String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"))
                .font(.system(size: 12))
        }
        .padding(.horizontal, BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding(horizontalPaddingRaw))
        .padding(.vertical, BrowserProfilePopoverDebugSettings.resolvedVerticalPadding(verticalPaddingRaw))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                )
        )
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Slider(value: value, in: range, step: 1)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }
}

private struct BrowserImportHintDebugView: View {
    @AppStorage(BrowserImportHintSettings.variantKey)
    private var variantRaw = BrowserImportHintSettings.defaultVariant.rawValue
    @AppStorage(BrowserImportHintSettings.showOnBlankTabsKey)
    private var showOnBlankTabs = BrowserImportHintSettings.defaultShowOnBlankTabs
    @AppStorage(BrowserImportHintSettings.dismissedKey)
    private var isDismissed = BrowserImportHintSettings.defaultDismissed

    private var selectedVariant: BrowserImportHintVariant {
        BrowserImportHintSettings.variant(for: variantRaw)
    }

    private var variantSelection: Binding<String> {
        Binding(
            get: { selectedVariant.rawValue },
            set: { variantRaw = BrowserImportHintSettings.variant(for: $0).rawValue }
        )
    }

    private var showOnBlankTabsBinding: Binding<Bool> {
        Binding(
            get: { showOnBlankTabs },
            set: { newValue in
                showOnBlankTabs = newValue
                if newValue {
                    isDismissed = false
                }
            }
        )
    }

    private var presentation: BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: selectedVariant,
            showOnBlankTabs: showOnBlankTabs,
            isDismissed: isDismissed
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Browser Import Hint")
                    .font(.headline)

                Text("Try lighter blank-tab import surfaces and dismissal states without touching the permanent Browser settings home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox("Variant") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Blank Tab Style", selection: variantSelection) {
                            ForEach(BrowserImportHintVariant.allCases) { variant in
                                Text(title(for: variant)).tag(variant.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(description(for: selectedVariant))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }

                GroupBox("State") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show on blank browser tabs", isOn: showOnBlankTabsBinding)
                        Toggle("Pretend the user dismissed it", isOn: $isDismissed)

                        Text("Current blank-tab placement: \(placementTitle(presentation.blankTabPlacement))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Settings status: \(settingsStatusTitle(presentation.settingsStatus))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Quick Actions") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button("Open Browser Settings") {
                                AppDelegate.presentPreferencesWindow(navigationTarget: .browser)
                            }
                            Button("Open Import Dialog") {
                                DispatchQueue.main.async {
                                    BrowserDataImportCoordinator.shared.presentImportDialog()
                                }
                            }
                        }

                        Button("Reset Hint Debug State") {
                            BrowserImportHintSettings.reset()
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Ideas") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Inline strip: default candidate, visible but quieter than the old floating card.")
                        Text("Floating card: strongest nudge, useful when we want more explanation.")
                        Text("Toolbar chip: most subtle, best when the hint should stay out of the content area.")
                        Text("Settings only: no in-browser nudge, Browser settings becomes the only permanent home.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func title(for variant: BrowserImportHintVariant) -> String {
        switch variant {
        case .inlineStrip:
            return "Inline Strip"
        case .floatingCard:
            return "Floating Card"
        case .toolbarChip:
            return "Toolbar Chip"
        case .settingsOnly:
            return "Settings Only"
        }
    }

    private func description(for variant: BrowserImportHintVariant) -> String {
        switch variant {
        case .inlineStrip:
            return "Shows a thin hint bar at the top of blank browser tabs."
        case .floatingCard:
            return "Shows the fuller callout card inside blank browser tabs."
        case .toolbarChip:
            return "Moves the hint into a small toolbar chip beside the browser controls."
        case .settingsOnly:
            return "Hides the blank-tab hint and leaves Browser settings as the only home."
        }
    }

    private func placementTitle(_ placement: BrowserImportHintBlankTabPlacement) -> String {
        switch placement {
        case .hidden:
            return "Hidden"
        case .inlineStrip:
            return "Inline Strip"
        case .floatingCard:
            return "Floating Card"
        case .toolbarChip:
            return "Toolbar Chip"
        }
    }

    private func settingsStatusTitle(_ status: BrowserImportHintSettingsStatus) -> String {
        switch status {
        case .visible:
            return "Visible"
        case .hidden:
            return "Hidden"
        case .settingsOnly:
            return "Settings Only"
        }
    }
}

private final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        window.center()
        window.contentView = NSHostingView(rootView: AboutPanelView())
        AboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .about)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        AboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .about)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

private final class AcknowledgmentsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AcknowledgmentsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = String(localized: "about.licenses.windowTitle", defaultValue: "Third-Party Licenses")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.licenses")
        window.center()
        window.contentView = NSHostingView(rootView: AcknowledgmentsView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct AcknowledgmentsView: View {
    private let content: String = {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md"),
           let text = try? String(contentsOf: url) {
            return text
        }
        return String(localized: "about.licenses.notFound", defaultValue: "Licenses file not found.")
    }()

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

// MARK: - File Explorer Style Debug

private struct FileExplorerStyleDebugView: View {
    @AppStorage("fileExplorer.style") private var styleRawValue: Int = 0

    private var currentStyle: FileExplorerStyle {
        FileExplorerStyle(rawValue: styleRawValue) ?? .liquidGlass
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File Explorer Style")
                .font(.headline)

            ForEach(FileExplorerStyle.allCases, id: \.rawValue) { style in
                HStack(spacing: 8) {
                    Button(action: {
                        styleRawValue = style.rawValue
                        // Post notification so outline view reloads with new style
                        NotificationCenter.default.post(name: .fileExplorerStyleDidChange, object: nil)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: styleRawValue == style.rawValue ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(styleRawValue == style.rawValue ? .accentColor : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.label)
                                    .font(.system(size: 13, weight: .medium))
                                Text(styleDescription(style))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(styleRawValue == style.rawValue
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Current: \(currentStyle.label)")
                    .font(.system(size: 11, weight: .medium))
                Text("Row: \(Int(currentStyle.rowHeight))pt, Indent: \(Int(currentStyle.indentation))pt, Icon: \(Int(currentStyle.iconSize))pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func styleDescription(_ style: FileExplorerStyle) -> String {
        switch style {
        case .liquidGlass: return "Modern macOS, vibrancy, rounded selections"
        case .highDensity: return "VS Code, compact rows, edge-to-edge"
        case .terminalStealth: return "Monospace, border selection, desaturated"
        case .proStudio: return "Logic Pro, chunky rows, pill selection"
        case .finder: return "Finder sidebar, filled icons, hover tint"
        }
    }
}

extension Notification.Name {
    static let fileExplorerStyleDidChange = Notification.Name("fileExplorerStyleDidChange")
    static let titlebarShortcutHintsVisibilityChanged = Notification.Name("titlebarShortcutHintsVisibilityChanged")
}

private final class FileExplorerStyleDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = FileExplorerStyleDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "File Explorer Style"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.fileExplorerStyleDebug")
        window.center()
        window.contentView = NSHostingView(rootView: FileExplorerStyleDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class SidebarDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SidebarDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidebar Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sidebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SidebarDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutPanelView: View {
    @Environment(\.openURL) private var openURL

    private let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private let docsURL = URL(string: "https://cmux.com/docs")

    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? {
        if let value = Bundle.main.infoDictionary?["CMUXCommit"] as? String, !value.isEmpty {
            return value
        }
        let env = ProcessInfo.processInfo.environment["CMUX_COMMIT"] ?? ""
        return env.isEmpty ? nil : env
    }
    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text(String(localized: "about.appName", defaultValue: "cmux"))
                        .bold()
                        .font(.title)
                    Text(String(localized: "about.description", defaultValue: "A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS."))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        AboutPropertyRow(label: String(localized: "about.version", defaultValue: "Version"), text: version)
                    }
                    if let build {
                        AboutPropertyRow(label: String(localized: "about.build", defaultValue: "Build"), text: build)
                    }
                    let commitText = commit ?? "—"
                    let commitURL = commit.flatMap { hash in
                        URL(string: "https://github.com/manaflow-ai/cmux/commit/\(hash)")
                    }
                    AboutPropertyRow(label: String(localized: "about.commit", defaultValue: "Commit"), text: commitText, url: commitURL)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button(String(localized: "about.docs", defaultValue: "Docs")) {
                            openURL(url)
                        }
                    }
                    if let url = githubURL {
                        Button(String(localized: "about.github", defaultValue: "GitHub")) {
                            openURL(url)
                        }
                    }
                    Button(String(localized: "about.licenses", defaultValue: "Licenses")) {
                        AcknowledgmentsWindowController.shared.show()
                    }
                }

                if let copy = copyright, !copy.isEmpty {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 280)
        .background(AboutVisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }
}

private struct SidebarDebugView: View {
    @AppStorage("sidebarMatchTerminalBackground") private var matchTerminalBackground = false
    @AppStorage("sidebarPreset") private var sidebarPreset = SidebarPresetOption.nativeSidebar.rawValue
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage(SidebarBranchDirectoryStackedSettings.key) private var sidebarBranchDirectoryStacked = SidebarBranchDirectoryStackedSettings.defaultStacked
    @AppStorage(SidebarPathLastSegmentSettings.key) private var sidebarPathLastSegmentOnly = SidebarPathLastSegmentSettings.defaultLastSegmentOnly
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage("sidebarSelectionColorHex") private var sidebarSelectionColorHex: String?

    private var selectedSidebarIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: sidebarActiveTabIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarIndicatorStyle.rawValue },
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar"))
                    .font(.headline)

                Toggle(String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"), isOn: $matchTerminalBackground)

                GroupBox("Presets") {
                    Picker("Preset", selection: $sidebarPreset) {
                        ForEach(SidebarPresetOption.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .onChange(of: sidebarPreset) { _ in
                        applyPreset()
                    }
                    .padding(.top, 2)
                }

                GroupBox("Blur") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Material", selection: $sidebarMaterial) {
                            ForEach(SidebarMaterialOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker("Blending", selection: $sidebarBlendMode) {
                            ForEach(SidebarBlendModeOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker("State", selection: $sidebarState) {
                            ForEach(SidebarStateOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        HStack(spacing: 8) {
                            Text("Strength")
                            Slider(value: $sidebarBlurOpacity, in: 0...1)
                            Text(String(format: "%.0f%%", sidebarBlurOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Tint") {
                    VStack(alignment: .leading, spacing: 8) {
                        ColorPicker("Tint Color", selection: tintColorBinding, supportsOpacity: false)

                        HStack(spacing: 8) {
                            Text("Opacity")
                            Slider(value: $sidebarTintOpacity, in: 0...0.7)
                            Text(String(format: "%.0f%%", sidebarTintOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Shape") {
                    HStack(spacing: 8) {
                        Text("Corner Radius")
                        Slider(value: $sidebarCornerRadius, in: 0...20)
                        Text(String(format: "%.0f", sidebarCornerRadius))
                            .font(.caption)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Active Workspace Indicator") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Style", selection: sidebarIndicatorStyleSelection) {
                            ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }

                        ColorPicker(String(localized: "sidebar.debug.selectionColor", defaultValue: "Selection Color"), selection: selectionColorBinding, supportsOpacity: false)

                        if sidebarSelectionColorHex != nil {
                            Button(String(localized: "sidebar.debug.resetSelectionColor", defaultValue: "Reset to Default")) {
                                sidebarSelectionColorHex = nil
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Workspace Metadata") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Render branch list vertically", isOn: $sidebarBranchVerticalLayout)
                        Text("When enabled, each branch appears on its own line in the sidebar.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button("Reset Tint") {
                        sidebarTintOpacity = 0.62
                        sidebarTintHex = SidebarTintDefaults.hex
                        sidebarTintHexLight = nil
                        sidebarTintHexDark = nil
                    }
                    Button("Reset Blur") {
                        sidebarMaterial = SidebarMaterialOption.hudWindow.rawValue
                        sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
                        sidebarState = SidebarStateOption.active.rawValue
                        sidebarBlurOpacity = 0.98
                    }
                    Button("Reset Shape") {
                        sidebarCornerRadius = 0.0
                    }
                    Button("Reset Active Indicator") {
                        sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
                        sidebarSelectionColorHex = nil
                    }
                }

                Button("Copy Config") {
                    copySidebarConfig()
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var tintColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: sidebarTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarTintHex = nsColor.hexString()
            }
        )
    }

    private func copySidebarConfig() {
        let payload = """
        sidebarPreset=\(sidebarPreset)
        sidebarMaterial=\(sidebarMaterial)
        sidebarBlendMode=\(sidebarBlendMode)
        sidebarState=\(sidebarState)
        sidebarBlurOpacity=\(String(format: "%.2f", sidebarBlurOpacity))
        sidebarTintHex=\(sidebarTintHex)
        sidebarTintHexLight=\(sidebarTintHexLight ?? "(nil)")
        sidebarTintHexDark=\(sidebarTintHexDark ?? "(nil)")
        sidebarTintOpacity=\(String(format: "%.2f", sidebarTintOpacity))
        sidebarCornerRadius=\(String(format: "%.1f", sidebarCornerRadius))
        sidebarBranchVerticalLayout=\(sidebarBranchVerticalLayout)
        sidebarBranchDirectoryStacked=\(sidebarBranchDirectoryStacked)
        sidebarPathLastSegmentOnly=\(sidebarPathLastSegmentOnly)
        sidebarActiveTabIndicatorStyle=\(sidebarActiveTabIndicatorStyle)
        sidebarDevBuildBannerVisible=\(showSidebarDevBuildBanner)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    private func applyPreset() {
        guard let preset = SidebarPresetOption(rawValue: sidebarPreset) else { return }
        sidebarMaterial = preset.material.rawValue
        sidebarBlendMode = preset.blendMode.rawValue
        sidebarState = preset.state.rawValue
        sidebarTintHex = preset.tintHex
        sidebarTintOpacity = preset.tintOpacity
        sidebarCornerRadius = preset.cornerRadius
        sidebarBlurOpacity = preset.blurOpacity
        sidebarTintHexLight = nil
        sidebarTintHexDark = nil
    }
}

// MARK: - Menu Bar Extra Debug Window

private final class MenuBarExtraDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MenuBarExtraDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Menu Bar Extra Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.menubarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: MenuBarExtraDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MenuBarExtraDebugView: View {
    @AppStorage(MenuBarIconDebugSettings.previewEnabledKey) private var previewEnabled = false
    @AppStorage(MenuBarIconDebugSettings.previewCountKey) private var previewCount = 1
    @AppStorage(MenuBarIconDebugSettings.badgeRectXKey) private var badgeRectX = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.x)
    @AppStorage(MenuBarIconDebugSettings.badgeRectYKey) private var badgeRectY = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.y)
    @AppStorage(MenuBarIconDebugSettings.badgeRectWidthKey) private var badgeRectWidth = Double(MenuBarIconDebugSettings.defaultBadgeRect.width)
    @AppStorage(MenuBarIconDebugSettings.badgeRectHeightKey) private var badgeRectHeight = Double(MenuBarIconDebugSettings.defaultBadgeRect.height)
    @AppStorage(MenuBarIconDebugSettings.singleDigitFontSizeKey) private var singleDigitFontSize = Double(MenuBarIconDebugSettings.defaultSingleDigitFontSize)
    @AppStorage(MenuBarIconDebugSettings.multiDigitFontSizeKey) private var multiDigitFontSize = Double(MenuBarIconDebugSettings.defaultMultiDigitFontSize)
    @AppStorage(MenuBarIconDebugSettings.singleDigitYOffsetKey) private var singleDigitYOffset = Double(MenuBarIconDebugSettings.defaultSingleDigitYOffset)
    @AppStorage(MenuBarIconDebugSettings.multiDigitYOffsetKey) private var multiDigitYOffset = Double(MenuBarIconDebugSettings.defaultMultiDigitYOffset)
    @AppStorage(MenuBarIconDebugSettings.singleDigitXAdjustKey) private var singleDigitXAdjust = Double(MenuBarIconDebugSettings.defaultSingleDigitXAdjust)
    @AppStorage(MenuBarIconDebugSettings.multiDigitXAdjustKey) private var multiDigitXAdjust = Double(MenuBarIconDebugSettings.defaultMultiDigitXAdjust)
    @AppStorage(MenuBarIconDebugSettings.textRectWidthAdjustKey) private var textRectWidthAdjust = Double(MenuBarIconDebugSettings.defaultTextRectWidthAdjust)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Menu Bar Extra Icon")
                    .font(.headline)

                GroupBox("Preview Count") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Override unread count", isOn: $previewEnabled)

                        Stepper(value: $previewCount, in: 0...99) {
                            HStack {
                                Text("Unread Count")
                                Spacer()
                                Text("\(previewCount)")
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                        }
                        .disabled(!previewEnabled)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Badge Rect") {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow("X", value: $badgeRectX, range: 0...20, format: "%.2f")
                        sliderRow("Y", value: $badgeRectY, range: 0...20, format: "%.2f")
                        sliderRow("Width", value: $badgeRectWidth, range: 4...14, format: "%.2f")
                        sliderRow("Height", value: $badgeRectHeight, range: 4...14, format: "%.2f")
                    }
                    .padding(.top, 2)
                }

                GroupBox("Badge Text") {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow("1-digit size", value: $singleDigitFontSize, range: 6...14, format: "%.2f")
                        sliderRow("2-digit size", value: $multiDigitFontSize, range: 6...14, format: "%.2f")
                        sliderRow("1-digit X", value: $singleDigitXAdjust, range: -4...4, format: "%.2f")
                        sliderRow("2-digit X", value: $multiDigitXAdjust, range: -4...4, format: "%.2f")
                        sliderRow("1-digit Y", value: $singleDigitYOffset, range: -3...4, format: "%.2f")
                        sliderRow("2-digit Y", value: $multiDigitYOffset, range: -3...4, format: "%.2f")
                        sliderRow("Text width adjust", value: $textRectWidthAdjust, range: -3...5, format: "%.2f")
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button("Reset") {
                        previewEnabled = false
                        previewCount = 1
                        badgeRectX = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.x)
                        badgeRectY = Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.y)
                        badgeRectWidth = Double(MenuBarIconDebugSettings.defaultBadgeRect.width)
                        badgeRectHeight = Double(MenuBarIconDebugSettings.defaultBadgeRect.height)
                        singleDigitFontSize = Double(MenuBarIconDebugSettings.defaultSingleDigitFontSize)
                        multiDigitFontSize = Double(MenuBarIconDebugSettings.defaultMultiDigitFontSize)
                        singleDigitYOffset = Double(MenuBarIconDebugSettings.defaultSingleDigitYOffset)
                        multiDigitYOffset = Double(MenuBarIconDebugSettings.defaultMultiDigitYOffset)
                        singleDigitXAdjust = Double(MenuBarIconDebugSettings.defaultSingleDigitXAdjust)
                        multiDigitXAdjust = Double(MenuBarIconDebugSettings.defaultMultiDigitXAdjust)
                        textRectWidthAdjust = Double(MenuBarIconDebugSettings.defaultTextRectWidthAdjust)
                        applyLiveUpdate()
                    }

                    Button("Copy Config") {
                        let payload = MenuBarIconDebugSettings.copyPayload()
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(payload, forType: .string)
                    }
                }

                Text("Tip: enable override count, then tune until the menu bar icon looks right.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { applyLiveUpdate() }
        .onChange(of: previewEnabled) { _ in applyLiveUpdate() }
        .onChange(of: previewCount) { _ in applyLiveUpdate() }
        .onChange(of: badgeRectX) { _ in applyLiveUpdate() }
        .onChange(of: badgeRectY) { _ in applyLiveUpdate() }
        .onChange(of: badgeRectWidth) { _ in applyLiveUpdate() }
        .onChange(of: badgeRectHeight) { _ in applyLiveUpdate() }
        .onChange(of: singleDigitFontSize) { _ in applyLiveUpdate() }
        .onChange(of: multiDigitFontSize) { _ in applyLiveUpdate() }
        .onChange(of: singleDigitXAdjust) { _ in applyLiveUpdate() }
        .onChange(of: multiDigitXAdjust) { _ in applyLiveUpdate() }
        .onChange(of: singleDigitYOffset) { _ in applyLiveUpdate() }
        .onChange(of: multiDigitYOffset) { _ in applyLiveUpdate() }
        .onChange(of: textRectWidthAdjust) { _ in applyLiveUpdate() }
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func applyLiveUpdate() {
        AppDelegate.shared?.refreshMenuBarExtraForDebug()
    }
}

// MARK: - Split Button Layout Debug Window

private final class SplitButtonLayoutDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SplitButtonLayoutDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Split Button Layout"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.splitButtonLayoutDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SplitButtonLayoutDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SplitButtonLayoutDebugView: View {
    @AppStorage("debugFadeColorStyle") private var backdropStyle = 0

    private var options: [(Int, String)] {
        [
            (0, String(localized: "debug.splitButtonLayout.option.precompositedPane", defaultValue: "Pre-composited paneBackground")),
            (1, String(localized: "debug.splitButtonLayout.option.rawPane", defaultValue: "Raw paneBackground (opaque)")),
            (2, String(localized: "debug.splitButtonLayout.option.rawBar", defaultValue: "barBackground (tab chrome)")),
            (3, String(localized: "debug.splitButtonLayout.option.windowBackground", defaultValue: "windowBackgroundColor")),
            (4, String(localized: "debug.splitButtonLayout.option.controlBackground", defaultValue: "controlBackgroundColor")),
            (5, String(localized: "debug.splitButtonLayout.option.precompositedBar", defaultValue: "Pre-composited barBackground")),
            (6, String(localized: "debug.splitButtonLayout.option.translucentChrome", defaultValue: "Translucent chrome")),
            (7, String(localized: "debug.splitButtonLayout.option.hidden", defaultValue: "Hidden")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "debug.splitButtonLayout.title", defaultValue: "Button Backdrop Color"))
                .font(.headline)

            ForEach(options, id: \.0) { id, label in
                HStack {
                    Image(systemName: backdropStyle == id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(backdropStyle == id ? .accentColor : .secondary)
                    Text(label)
                }
                .contentShape(Rectangle())
                .onTapGesture { backdropStyle = id }
            }

            Text(String(localized: "debug.splitButtonLayout.liveNote", defaultValue: "Changes apply live."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Tab Bar Backdrop Lab Window

private final class TabBarBackdropLabWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TabBarBackdropLabWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1040),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.tabBarBackdropLab.title", defaultValue: "Tab Bar Backdrop Lab")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .floating
        window.identifier = NSUserInterfaceItemIdentifier("cmux.tabBarBackdropLab")
        window.center()

        let hostingView = NSHostingView(rootView: TabBarBackdropLabView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

private struct TabBarBackdropLabView: View {
    @State private var opacity: Double
    @State private var sidebarWidth: Double = 74
    @State private var sampleWidth: Double = 460
    @State private var candidateSoftness: Double = Double(Workspace.bonsplitSplitButtonBackdropSoftness)

    init() {
        let currentOpacity = Double(WindowAppearanceSnapshot.clampedOpacity(GhosttyApp.shared.defaultBackgroundOpacity))
        _opacity = State(initialValue: currentOpacity < 0.999 ? currentOpacity : 0.72)
    }

    private var terminalColor: NSColor {
        GhosttyApp.shared.defaultBackgroundColor.usingColorSpace(.sRGB) ?? NSColor(hex: "#646461") ?? .windowBackgroundColor
    }

    private var surfaceColor: NSColor {
        terminalColor.withAlphaComponent(CGFloat(opacity))
    }

    private var separatorColor: NSColor {
        WindowChromeSeparatorColor.color(forChromeBackground: terminalColor)
    }

    private var candidateBackdropEffect: BonsplitConfiguration.Appearance.SplitButtonBackdropEffect {
        let softness = CGFloat(min(max(0, candidateSoftness), 1))
        let productionSoftness = Workspace.bonsplitSplitButtonBackdropSoftness
        let production = Workspace.bonsplitSplitButtonBackdropEffect()
        func interpolate(strong: CGFloat, production: CGFloat, soft: CGFloat) -> CGFloat {
            if softness <= productionSoftness {
                let progress = softness / productionSoftness
                return strong + ((production - strong) * progress)
            }
            let progress = (softness - productionSoftness) / (1 - productionSoftness)
            return production + ((soft - production) * progress)
        }

        return .init(
            style: .translucentChrome,
            fadeWidth: interpolate(strong: 20, production: production.fadeWidth, soft: 240),
            contentFadeWidth: interpolate(strong: 0, production: production.contentFadeWidth, soft: 80),
            solidWidth: interpolate(strong: 72, production: production.solidWidth, soft: 0),
            solidSurfaceWidthAdjustment: production.solidSurfaceWidthAdjustment,
            fadeRampStartFraction: interpolate(strong: 0, production: production.fadeRampStartFraction, soft: 0.98),
            leadingOpacity: production.leadingOpacity,
            trailingOpacity: interpolate(strong: 1.0, production: production.trailingOpacity, soft: 0.25),
            contentOcclusionFraction: interpolate(strong: 0, production: production.contentOcclusionFraction, soft: 1),
            masksTabContent: true
        )
    }

    private var variants: [TabBarBackdropLabVariant] {
        let chromeHex = surfaceColor.hexString(includeAlpha: true)
        let paneHex = "#00000000"
        let borderHex = separatorColor.hexString(includeAlpha: true)
        let opacityValue = CGFloat(opacity)
        let candidate = candidateBackdropEffect

        return [
            variant(
                id: "candidate",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidate", defaultValue: "Candidate"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidate.detail", defaultValue: "Translucent chrome with tab occlusion."),
                effect: candidate,
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "candidateWideFade",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidateWideFade", defaultValue: "Wide fade"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidateWideFade.detail", defaultValue: "Same model with a softer edge."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 104,
                    contentFadeWidth: 46,
                    solidWidth: 10,
                    fadeRampStartFraction: 0.88,
                    leadingOpacity: 0,
                    trailingOpacity: 1.0,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "candidateSoftEnd",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidateSoftEnd", defaultValue: "Soft end"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidateSoftEnd.detail", defaultValue: "Same mask with lighter button fill."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 100,
                    contentFadeWidth: 42,
                    solidWidth: 14,
                    fadeRampStartFraction: 0.84,
                    leadingOpacity: 0,
                    trailingOpacity: 0.82,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "candidateTightEdge",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidateTightEdge", defaultValue: "Tight edge"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidateTightEdge.detail", defaultValue: "More coverage at the fade start."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 90,
                    contentFadeWidth: 34,
                    solidWidth: 24,
                    fadeRampStartFraction: 0.70,
                    leadingOpacity: 0.08,
                    trailingOpacity: 1.0,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "candidateLowContrast",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidateLowContrast", defaultValue: "Low contrast"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidateLowContrast.detail", defaultValue: "Lower-opacity solid region."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 102,
                    contentFadeWidth: 38,
                    solidWidth: 12,
                    fadeRampStartFraction: 0.86,
                    leadingOpacity: 0,
                    trailingOpacity: 0.72,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "translucentChrome",
                title: String(localized: "debug.tabBarBackdropLab.variant.translucentChrome", defaultValue: "6 Translucent chrome"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.translucentChrome.detail", defaultValue: "Shows the bleed-through problem."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 96,
                    contentFadeWidth: 42,
                    solidWidth: 18,
                    fadeRampStartFraction: 0.82,
                    leadingOpacity: 0,
                    trailingOpacity: 1.0,
                    masksTabContent: false
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "translucentNoFade",
                title: String(localized: "debug.tabBarBackdropLab.variant.translucentNoFade", defaultValue: "No fade"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.translucentNoFade.detail", defaultValue: "Hard translucent edge for contrast."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 0,
                    solidWidth: 30,
                    leadingOpacity: 1.0,
                    trailingOpacity: 1.0,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "hidden",
                title: String(localized: "debug.tabBarBackdropLab.variant.hidden", defaultValue: "7 No backdrop"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.hidden.detail", defaultValue: "Control sample. Tabs remain visible below the buttons."),
                effect: .init(style: .hidden, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "precompositedPane",
                title: String(localized: "debug.tabBarBackdropLab.variant.precompositedPane", defaultValue: "0 Opaque pane composite"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.precompositedPane.detail", defaultValue: "Old candidate. Covers too hard."),
                effect: .init(style: .precompositedPaneBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "opaquePane",
                title: String(localized: "debug.tabBarBackdropLab.variant.opaquePane", defaultValue: "1 Raw pane opaque"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.opaquePane.detail", defaultValue: "Forces the pane fill to full opacity."),
                effect: .init(style: .opaquePaneBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "opaqueBar",
                title: String(localized: "debug.tabBarBackdropLab.variant.opaqueBar", defaultValue: "2 Raw bar opaque"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.opaqueBar.detail", defaultValue: "Uses the tab chrome color at full opacity."),
                effect: .init(style: .opaqueBarBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "precompositedBar",
                title: String(localized: "debug.tabBarBackdropLab.variant.precompositedBar", defaultValue: "5 Opaque bar composite"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.precompositedBar.detail", defaultValue: "Composites tab chrome over the window background."),
                effect: .init(style: .precompositedBarBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "windowBackground",
                title: String(localized: "debug.tabBarBackdropLab.variant.windowBackground", defaultValue: "3 Window background"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.windowBackground.detail", defaultValue: "Uses AppKit windowBackgroundColor."),
                effect: .init(style: .windowBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "controlBackground",
                title: String(localized: "debug.tabBarBackdropLab.variant.controlBackground", defaultValue: "4 Control background"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.controlBackground.detail", defaultValue: "Uses AppKit controlBackgroundColor."),
                effect: .init(style: .controlBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
        ]
    }

    private var sampleWidthValue: CGFloat {
        CGFloat(sampleWidth)
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.fixed(sampleWidthValue), spacing: 16, alignment: .top),
            GridItem(.fixed(sampleWidthValue), spacing: 16, alignment: .top),
            GridItem(.fixed(sampleWidthValue), spacing: 16, alignment: .top),
        ]
    }

    private var gridContentWidth: CGFloat {
        sampleWidthValue * 3 + 32
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "debug.tabBarBackdropLab.title", defaultValue: "Tab Bar Backdrop Lab"))
                        .font(.headline)
                    Text(String(localized: "debug.tabBarBackdropLab.subtitle", defaultValue: "Live Bonsplit tab bars with overflow tabs under the split buttons. The window background is transparent."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 18) {
                    labSlider(
                        title: String(localized: "debug.tabBarBackdropLab.opacity", defaultValue: "Surface opacity"),
                        value: $opacity,
                        range: 0.2...1.0,
                        displayValue: "\(Int(opacity * 100))%",
                        width: 150
                    )
                    labSlider(
                        title: String(localized: "debug.tabBarBackdropLab.width", defaultValue: "Sample width"),
                        value: $sampleWidth,
                        range: 390...580,
                        displayValue: "\(Int(sampleWidth))",
                        width: 140
                    )
                    labSlider(
                        title: String(localized: "debug.tabBarBackdropLab.candidateSoftness", defaultValue: "Candidate softness"),
                        value: $candidateSoftness,
                        range: 0...1,
                        displayValue: "\(Int(candidateSoftness * 100))%",
                        width: 180
                    )
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            ScrollView {
                LazyVGrid(
                    columns: gridColumns,
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(variants) { variant in
                        TabBarBackdropLabSample(
                            variant: variant,
                            sidebarWidth: CGFloat(sidebarWidth)
                        )
                        .id(variant.renderIdentity)
                        .frame(width: sampleWidthValue, alignment: .topLeading)
                    }
                }
                .frame(minWidth: gridContentWidth, alignment: .leading)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.visible)
        }
        .padding(18)
        .background(Color.clear)
        .frame(minWidth: 1320, minHeight: 820)
    }

    private func variant(
        id: String,
        title: String,
        detail: String,
        effect: BonsplitConfiguration.Appearance.SplitButtonBackdropEffect,
        chromeHex: String,
        tabBarHex: String? = nil,
        splitButtonBackdropHex: String? = nil,
        paneHex: String,
        borderHex: String,
        opacity: CGFloat
    ) -> TabBarBackdropLabVariant {
        TabBarBackdropLabVariant(
            id: id,
            title: title,
            detail: detail,
            effect: effect,
            chromeHex: chromeHex,
            tabBarHex: tabBarHex ?? chromeHex,
            splitButtonBackdropHex: splitButtonBackdropHex ?? tabBarHex ?? chromeHex,
            paneHex: paneHex,
            borderHex: borderHex,
            terminalColor: terminalColor,
            surfaceColor: surfaceColor,
            separatorColor: separatorColor,
            opacity: opacity
        )
    }

    private func labSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String,
        width: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) \(displayValue)")
                .font(.caption.monospacedDigit())
                .lineLimit(1)
            Slider(value: value, in: range)
                .frame(width: width)
        }
    }
}

private struct TabBarBackdropLabSample: View {
    let variant: TabBarBackdropLabVariant
    let sidebarWidth: CGFloat
    @State private var controller: BonsplitController

    init(variant: TabBarBackdropLabVariant, sidebarWidth: CGFloat) {
        self.variant = variant
        self.sidebarWidth = sidebarWidth
        _controller = State(initialValue: Self.makeController(for: variant))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(variant.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(variant.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                TabBarBackdropLabSidebar(
                    title: String(localized: "debug.tabBarBackdropLab.leftSidebar", defaultValue: "L"),
                    surfaceColor: variant.surfaceColor,
                    separatorColor: variant.separatorColor,
                    trailingBorder: true
                )
                .frame(width: sidebarWidth)

                VStack(spacing: 0) {
                    TabBarBackdropLabTitlebar(
                        variant: variant,
                        title: String(localized: "debug.tabBarBackdropLab.titlebarSample", defaultValue: "workspace@lab:~")
                    )
                    .frame(height: 24)

                    BonsplitView(controller: controller) { tab, _ in
                        TabBarBackdropLabTerminalPane(
                            title: tab.title,
                            color: variant.terminalColor,
                            opacity: variant.opacity
                        )
                    } emptyPane: { _ in
                        Color.clear
                    }
                }
                .frame(height: 132)

                TabBarBackdropLabSidebar(
                    title: String(localized: "debug.tabBarBackdropLab.rightSidebar", defaultValue: "R"),
                    surfaceColor: variant.surfaceColor,
                    separatorColor: variant.separatorColor,
                    trailingBorder: false
                )
                .frame(width: sidebarWidth)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(nsColor: variant.separatorColor), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            applyVariant()
        }
        .onChange(of: variant.renderIdentity) { _, _ in
            applyVariant()
        }
    }

    private func applyVariant() {
        controller.configuration = Self.makeConfiguration(for: variant)
    }

    private static func makeAppearance(for variant: TabBarBackdropLabVariant) -> BonsplitConfiguration.Appearance {
        BonsplitConfiguration.Appearance(
            tabBarHeight: WindowChromeMetrics.bonsplitTabBarHeight,
            tabMinWidth: 138,
            tabMaxWidth: 210,
            tabTitleFontSize: 11,
            tabSpacing: 0,
            minimumPaneWidth: 120,
            minimumPaneHeight: 80,
            showSplitButtons: true,
            splitButtons: BonsplitConfiguration.SplitActionButton.defaults,
            splitButtonsOnHover: false,
            splitButtonBackdropEffect: variant.effect,
            animationDuration: 0.0,
            enableAnimations: false,
            chromeColors: .init(
                backgroundHex: variant.chromeHex,
                tabBarBackgroundHex: variant.tabBarHex,
                splitButtonBackdropHex: variant.splitButtonBackdropHex,
                paneBackgroundHex: variant.paneHex,
                borderHex: variant.borderHex
            )
        )
    }

    private static func makeConfiguration(for variant: TabBarBackdropLabVariant) -> BonsplitConfiguration {
        BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowTabReordering: false,
            allowCrossPaneTabMove: false,
            autoCloseEmptyPanes: false,
            contentViewLifecycle: .recreateOnSwitch,
            newTabPosition: .end,
            appearance: makeAppearance(for: variant)
        )
    }

    private static func makeController(for variant: TabBarBackdropLabVariant) -> BonsplitController {
        let controller = BonsplitController(configuration: makeConfiguration(for: variant))

        let titles = [
            String(localized: "debug.tabBarBackdropLab.tab.agentBrowserLogs", defaultValue: "agent-browser logs"),
            String(localized: "debug.tabBarBackdropLab.tab.terminalTransparency", defaultValue: "cmux terminal transparency"),
            String(localized: "debug.tabBarBackdropLab.tab.underlayText", defaultValue: "underlay tab text visible here"),
            String(localized: "debug.tabBarBackdropLab.tab.backdropCheck", defaultValue: "split button backdrop check"),
            String(localized: "debug.tabBarBackdropLab.tab.rightEdgeOverflow", defaultValue: "right edge overflow sample"),
            String(localized: "debug.tabBarBackdropLab.tab.hiddenBelowControls", defaultValue: "tabs hidden below controls")
        ]
        let tabs = titles.enumerated().compactMap { index, title in
            controller.createTab(
                title: title,
                icon: index == 0 ? "terminal" : "doc.text",
                isDirty: index == 2,
                showsNotificationBadge: index == 4
            )
        }
        if let selected = tabs.dropFirst(4).first ?? tabs.first {
            controller.selectTab(selected)
        }
        return controller
    }
}

private struct TabBarBackdropLabTitlebar: View {
    let variant: TabBarBackdropLabVariant
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.red.opacity(0.75)).frame(width: 8, height: 8)
                Circle().fill(Color.yellow.opacity(0.75)).frame(width: 8, height: 8)
                Circle().fill(Color.green.opacity(0.75)).frame(width: 8, height: 8)
            }
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .background(Color(nsColor: variant.surfaceColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: variant.separatorColor))
                .frame(height: 1)
        }
    }
}

private struct TabBarBackdropLabSidebar: View {
    let title: String
    let surfaceColor: NSColor
    let separatorColor: NSColor
    let trailingBorder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(index == 0 ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12))
                    .frame(height: 18)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: surfaceColor))
        .overlay(alignment: trailingBorder ? .trailing : .leading) {
            Rectangle()
                .fill(Color(nsColor: separatorColor))
                .frame(width: 1)
        }
    }
}

private struct TabBarBackdropLabTerminalPane: View {
    let title: String
    let color: NSColor
    let opacity: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: color.withAlphaComponent(opacity))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(String(localized: "debug.tabBarBackdropLab.terminal.prompt", defaultValue: "lawrence in ~/cmux")) \(title)")
                    .foregroundStyle(Color.green)
                Text(String(localized: "debug.tabBarBackdropLab.terminal.overflow", defaultValue: "tab titles intentionally overflow under the split buttons"))
                    .foregroundStyle(Color.white.opacity(0.78))
                Text(String(localized: "debug.tabBarBackdropLab.terminal.compare", defaultValue: "drag / resize / compare the transparent edges"))
                    .foregroundStyle(Color.white.opacity(0.52))
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(10)
        }
    }
}

// MARK: - Background Debug Window

private final class BackgroundDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BackgroundDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Background Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.backgroundDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BackgroundDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BackgroundDebugView: View {
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassMaterial") private var bgGlassMaterial = "hudWindow"
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Window Background Glass")
                    .font(.headline)

                GroupBox("Glass Effect") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Glass Effect", isOn: $bgGlassEnabled)

                        Picker("Material", selection: $bgGlassMaterial) {
                            Text("HUD Window").tag("hudWindow")
                            Text("Under Window").tag("underWindowBackground")
                            Text("Sidebar").tag("sidebar")
                            Text("Menu").tag("menu")
                            Text("Popover").tag("popover")
                        }
                        .disabled(!bgGlassEnabled)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Tint") {
                    VStack(alignment: .leading, spacing: 8) {
                        ColorPicker("Tint Color", selection: tintColorBinding, supportsOpacity: false)
                            .disabled(!bgGlassEnabled)

                        HStack(spacing: 8) {
                            Text("Opacity")
                            Slider(value: $bgGlassTintOpacity, in: 0...0.8)
                                .disabled(!bgGlassEnabled)
                            Text(String(format: "%.0f%%", bgGlassTintOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button("Reset") {
                        bgGlassTintHex = "#000000"
                        bgGlassTintOpacity = 0.03
                        bgGlassMaterial = "hudWindow"
                        bgGlassEnabled = false
                        updateWindowGlassTint()
                    }

                    Button("Copy Config") {
                        copyBgConfig()
                    }
                }

                Text("Tint changes apply live. Enable/disable requires reload.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: bgGlassTintHex) { _ in updateWindowGlassTint() }
        .onChange(of: bgGlassTintOpacity) { _ in updateWindowGlassTint() }
    }

    private func updateWindowGlassTint() {
        let window: NSWindow? = {
            if let key = NSApp.keyWindow,
               let raw = key.identifier?.rawValue,
               raw == "cmux.main" || raw.hasPrefix("cmux.main.") {
                return key
            }
            return NSApp.windows.first(where: {
                guard let raw = $0.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            })
        }()
        guard let window else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        WindowBackdropController.updateGlassTint(to: window, color: tintColor)
    }

    private var tintColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: bgGlassTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                bgGlassTintHex = nsColor.hexString()
            }
        )
    }

    private func copyBgConfig() {
        let payload = """
        bgGlassEnabled=\(bgGlassEnabled)
        bgGlassMaterial=\(bgGlassMaterial)
        bgGlassTintHex=\(bgGlassTintHex)
        bgGlassTintOpacity=\(String(format: "%.2f", bgGlassTintOpacity))
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
}

private final class StartupAppearanceDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = StartupAppearanceDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.startupAppearance.window.title",
            defaultValue: "Startup Appearance Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.startupAppearanceDebug")
        window.center()
        window.contentView = NSHostingView(rootView: StartupAppearanceDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum StartupAppearancePreviewMode: String, CaseIterable, Identifiable {
    case stored
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stored:
            return String(
                localized: "debug.startupAppearance.mode.stored",
                defaultValue: "Stored App Setting"
            )
        case .light:
            return String(
                localized: "debug.startupAppearance.mode.light",
                defaultValue: "Force Light"
            )
        case .dark:
            return String(
                localized: "debug.startupAppearance.mode.dark",
                defaultValue: "Force Dark"
            )
        }
    }
}

private struct StartupAppearanceDebugView: View {
    @State private var selectedProfile = GhosttyStartupAppearancePreviewState.profile
    @State private var selectedAppearance = StartupAppearancePreviewMode.stored
    @State private var lastAppliedProfile = GhosttyStartupAppearancePreviewState.profile
    @State private var lastAppliedAppearance = StartupAppearancePreviewMode.stored

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    String(
                        localized: "debug.startupAppearance.window.title",
                        defaultValue: "Startup Appearance Debug"
                    )
                )
                    .font(.headline)

                GroupBox(
                    String(
                        localized: "debug.startupAppearance.preview.heading",
                        defaultValue: "Preview"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(
                            String(
                                localized: "debug.startupAppearance.startupConfig.label",
                                defaultValue: "Startup config"
                            ),
                            selection: $selectedProfile
                        ) {
                            ForEach(GhosttyStartupAppearancePreviewProfile.allCases) { profile in
                                Text(profile.displayName).tag(profile)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(selectedProfile.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker(
                            String(
                                localized: "debug.startupAppearance.appearance.label",
                                defaultValue: "Appearance"
                            ),
                            selection: $selectedAppearance
                        ) {
                            ForEach(StartupAppearancePreviewMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Button(
                                String(
                                    localized: "debug.startupAppearance.applyPreview.button",
                                    defaultValue: "Apply Preview"
                                )
                            ) {
                                applyPreview()
                            }
                            .keyboardShortcut(.defaultAction)

                            Button(
                                String(
                                    localized: "debug.startupAppearance.restoreRealStartup.button",
                                    defaultValue: "Restore Real Startup"
                                )
                            ) {
                                restoreRealStartup()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(
                    String(
                        localized: "debug.startupAppearance.selectedConfig.heading",
                        defaultValue: "Selected Config"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView {
                            Text(selectedConfigText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(8)
                        }
                        .frame(minHeight: 92, maxHeight: 150)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Button(
                            String(
                                localized: "debug.startupAppearance.copySelectedConfig.button",
                                defaultValue: "Copy Selected Config"
                            )
                        ) {
                            copySelectedConfig()
                        }
                        .disabled(selectedPreviewConfigText == nil)
                    }
                    .padding(.top, 2)
                }

                GroupBox(
                    String(
                        localized: "debug.startupAppearance.applied.heading",
                        defaultValue: "Applied"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(
                                String(
                                    localized: "debug.startupAppearance.applied.configLabel",
                                    defaultValue: "Config:"
                                )
                            )
                            Text(lastAppliedProfile.displayName)
                        }
                        HStack(spacing: 4) {
                            Text(
                                String(
                                    localized: "debug.startupAppearance.applied.appearanceLabel",
                                    defaultValue: "Appearance:"
                                )
                            )
                            Text(lastAppliedAppearance.displayName)
                        }
                        Text(
                            String(
                                localized: "debug.startupAppearance.applied.help",
                                defaultValue: "Reloads the running app through Ghostty config update, matching startup theme resolution without editing config files."
                            )
                        )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedPreviewConfigText: String? {
        selectedProfile.previewConfigContents()
    }

    private var selectedConfigText: String {
        selectedPreviewConfigText ?? String(
            localized: "debug.startupAppearance.realConfigFallback",
            defaultValue: "Loads real user config files."
        )
    }

    private func applyPreview() {
        applyAppearance(selectedAppearance)
        GhosttyStartupAppearancePreviewState.profile = selectedProfile
        GhosttyConfig.invalidateLoadCache()
        GhosttyApp.shared.reloadConfiguration(
            source: "debug.startupAppearancePreview",
            reloadSettingsFromFile: false
        )
        lastAppliedProfile = selectedProfile
        lastAppliedAppearance = selectedAppearance
    }

    private func restoreRealStartup() {
        selectedProfile = .realUserConfig
        selectedAppearance = .stored
        applyAppearance(.stored)
        GhosttyStartupAppearancePreviewState.profile = .realUserConfig
        GhosttyConfig.invalidateLoadCache()
        GhosttyApp.shared.reloadConfiguration(
            source: "debug.startupAppearanceRestore",
            reloadSettingsFromFile: false
        )
        lastAppliedProfile = .realUserConfig
        lastAppliedAppearance = .stored
    }

    private func applyAppearance(_ mode: StartupAppearancePreviewMode) {
        switch mode {
        case .stored:
            switch AppearanceSettings.resolvedMode() {
            case .system, .auto:
                NSApplication.shared.appearance = nil
            case .light:
                NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case .dark:
                NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            }
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func copySelectedConfig() {
        guard let config = selectedPreviewConfigText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(config, forType: .string)
    }
}

private struct AboutPropertyRow: View {
    private let label: String
    private let text: String
    private let url: URL?

    init(label: String, text: String, url: URL? = nil) {
        self.label = label
        self.text = text
        self.url = url
    }

    @ViewBuilder private var textView: some View {
        Text(text)
            .frame(width: 140, alignment: .leading)
            .padding(.leading, 2)
            .tint(.secondary)
            .opacity(0.8)
            .monospaced()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 126, alignment: .trailing)
                .padding(.trailing, 2)
            if let url {
                Link(destination: url) {
                    textView
                }
            } else {
                textView
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }
}

private struct AboutVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let isEmphasized: Bool

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        isEmphasized: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.isEmphasized = isEmphasized
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffect = NSVisualEffectView()
        visualEffect.autoresizingMask = [.width, .height]
        return visualEffect
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case ar
    case bs
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case da
    case de
    case es
    case fr
    case it
    case ja
    case ko
    case nb
    case pl
    case ptBR = "pt-BR"
    case ru
    case th
    case tr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "language.system", defaultValue: "System")
        case .en: return "English"
        case .ar: return "\u{200E}العربية (Arabic)"
        case .bs: return "Bosanski (Bosnian)"
        case .zhHans: return "简体中文 (Chinese Simplified)"
        case .zhHant: return "繁體中文 (Chinese Traditional)"
        case .da: return "Dansk (Danish)"
        case .de: return "Deutsch (German)"
        case .es: return "Español (Spanish)"
        case .fr: return "Français (French)"
        case .it: return "Italiano (Italian)"
        case .ja: return "日本語 (Japanese)"
        case .ko: return "한국어 (Korean)"
        case .nb: return "Norsk (Norwegian)"
        case .pl: return "Polski (Polish)"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский (Russian)"
        case .th: return "ไทย (Thai)"
        case .tr: return "Türkçe (Turkish)"
        }
    }
}

enum LanguageSettings {
    static let languageKey = "appLanguage"
    static let defaultLanguage: AppLanguage = .system

    static func apply(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    static var languageAtLaunch: AppLanguage = {
        let stored = UserDefaults.standard.string(forKey: languageKey)
        guard let stored, let lang = AppLanguage(rawValue: stored) else { return .system }
        return lang
    }()
}

enum AppIconMode: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "appIcon.automatic", defaultValue: "Automatic")
        case .light: return String(localized: "appIcon.light", defaultValue: "Light")
        case .dark: return String(localized: "appIcon.dark", defaultValue: "Dark")
        }
    }

    var imageName: String? {
        switch self {
        case .automatic: return nil
        case .light: return "AppIconLight"
        case .dark: return "AppIconDark"
        }
    }
}

enum AppIconLaunchState {
    private static let lock = NSLock()
    private static var didFinishLaunching = false

    static func markDidFinishLaunching() {
        lock.lock()
        defer { lock.unlock() }
        didFinishLaunching = true
    }

    static func isApplicationFinishedLaunching() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let hasFinishedLaunching = didFinishLaunching
        return hasFinishedLaunching
    }
}

enum AppIconSettings {
    static let modeKey = "appIconMode"
    static let defaultMode: AppIconMode = .automatic
    private static let dockTileIconDidChangeNotification = Notification.Name("com.cmuxterm.appIconDidChange")
    private static var liveEnvironmentProvider: () -> Environment = { .live() }

    private static func isRunningUnderXCTest(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if env["XCInjectBundle"] != nil { return true }
        if env["XCInjectBundleInto"] != nil { return true }
        if env["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if env.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        return false
    }

    struct Environment {
        let isApplicationFinishedLaunching: () -> Bool
        let imageForMode: (AppIconMode) -> NSImage?
        let setApplicationIconImage: (NSImage) -> Void
        let startAppearanceObservation: () -> Void
        let stopAppearanceObservation: () -> Void
        let notifyDockTilePlugin: () -> Void

        static func live() -> Self {
            Self(
                isApplicationFinishedLaunching: {
                    AppIconLaunchState.isApplicationFinishedLaunching()
                },
                imageForMode: { mode in
                    guard let imageName = mode.imageName else { return nil }
                    return NSImage(named: imageName)
                },
                setApplicationIconImage: { icon in
                    NSApplication.shared.applicationIconImage = icon
                },
                startAppearanceObservation: {
                    AppIconAppearanceObserver.shared.startObserving()
                },
                stopAppearanceObservation: {
                    AppIconAppearanceObserver.shared.stopObserving()
                },
                notifyDockTilePlugin: {
                    guard !AppIconSettings.isRunningUnderXCTest() else { return }
                    DistributedNotificationCenter.default().postNotificationName(
                        AppIconSettings.dockTileIconDidChangeNotification,
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                }
            )
        }
    }

    static func resolvedMode(defaults: UserDefaults = .standard) -> AppIconMode {
        guard let raw = defaults.string(forKey: modeKey),
              let mode = AppIconMode(rawValue: raw) else {
            return defaultMode
        }
        return mode
    }

    static func applyIcon(_ mode: AppIconMode, environment: Environment? = nil) {
        let environment = environment ?? liveEnvironmentProvider()
        // Tahoe can crash or wedge when app icon work runs during App.init(),
        // so leave settings replay to update defaults only and let AppDelegate
        // apply the resolved icon once didFinishLaunching begins.
        guard environment.isApplicationFinishedLaunching() else { return }

        switch mode {
        case .automatic:
            environment.startAppearanceObservation()
        case .light:
            environment.stopAppearanceObservation()
            guard let icon = environment.imageForMode(.light) else { return }
            environment.setApplicationIconImage(icon)
        case .dark:
            environment.stopAppearanceObservation()
            guard let icon = environment.imageForMode(.dark) else { return }
            environment.setApplicationIconImage(icon)
        }

        environment.notifyDockTilePlugin()
    }

    static func setLiveEnvironmentProviderForTesting(_ provider: @escaping () -> Environment) {
        liveEnvironmentProvider = provider
    }

    static func resetLiveEnvironmentProviderForTesting() {
        liveEnvironmentProvider = { .live() }
    }
}

protocol AppIconAppearanceObservation: AnyObject {
    func invalidate()
}

extension NSKeyValueObservation: AppIconAppearanceObservation {}

final class AppIconAppearanceObserver: NSObject {
    struct Environment {
        let isApplicationFinishedLaunching: () -> Bool
        let startEffectiveAppearanceObservation: (@escaping () -> Void) -> AppIconAppearanceObservation?
        let addDidFinishLaunchingObserver: (@escaping () -> Void) -> NSObjectProtocol
        let removeObserver: (NSObjectProtocol) -> Void
        let currentAppearanceIsDark: () -> Bool?
        let imageForName: (String) -> NSImage?
        let setApplicationIconImage: (NSImage) -> Void

        static func live() -> Self {
            Self(
                isApplicationFinishedLaunching: {
                    AppIconLaunchState.isApplicationFinishedLaunching()
                },
                startEffectiveAppearanceObservation: { handler in
                    guard let app = NSApp else { return nil }
                    return app.observe(\.effectiveAppearance, options: []) { _, _ in
                        DispatchQueue.main.async {
                            handler()
                        }
                    }
                },
                addDidFinishLaunchingObserver: { handler in
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.didFinishLaunchingNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        handler()
                    }
                },
                removeObserver: { observer in
                    NotificationCenter.default.removeObserver(observer)
                },
                currentAppearanceIsDark: {
                    guard let app = NSApp else { return nil }
                    return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                },
                imageForName: { imageName in
                    NSImage(named: imageName)
                },
                setApplicationIconImage: { icon in
                    NSApplication.shared.applicationIconImage = icon
                }
            )
        }
    }

    static let shared = AppIconAppearanceObserver()
    private let environment: Environment
    private var observation: AppIconAppearanceObservation?
    private var launchObserver: NSObjectProtocol?
    private var hasDeferredStartPending = false
    private var lastAppliedImageName: String?

    init(environment: Environment = .live()) {
        self.environment = environment
        super.init()
    }
    func startObserving() {
        // Tahoe crashes if effectiveAppearance is touched during App.init(),
        // so defer the first automatic-icon apply until launch completes.
        if !environment.isApplicationFinishedLaunching() {
            deferStartUntilLaunchIfNeeded()
            return
        }

        cancelDeferredStart()
        applyIconForCurrentAppearance()
        guard observation == nil else { return }
        observation = environment.startEffectiveAppearanceObservation { [weak self] in
            guard let self, self.observation != nil else { return }
            self.applyIconForCurrentAppearance()
        }
    }

    func stopObserving() {
        observation?.invalidate()
        observation = nil
        lastAppliedImageName = nil
        cancelDeferredStart()
    }
    private func deferStartUntilLaunchIfNeeded() {
        hasDeferredStartPending = true
        guard launchObserver == nil else { return }
        launchObserver = environment.addDidFinishLaunchingObserver { [weak self] in
            guard let self, self.hasDeferredStartPending else { return }
            self.cancelDeferredStart()
            self.startObserving()
        }
    }

    private func cancelDeferredStart() {
        hasDeferredStartPending = false
        guard let launchObserver else { return }
        environment.removeObserver(launchObserver)
        self.launchObserver = nil
    }
    private func applyIconForCurrentAppearance() {
        guard environment.isApplicationFinishedLaunching() else { return }
        guard let isDark = environment.currentAppearanceIsDark() else { return }
        let imageName = isDark ? "AppIconDark" : "AppIconLight"
        guard imageName != lastAppliedImageName,
              let icon = environment.imageForName(imageName) else { return }
        environment.setApplicationIconImage(icon)
        lastAppliedImageName = imageName
    }
}

enum QuitWarningSettings {
    static let warnBeforeQuitKey = "warnBeforeQuitShortcut"
    static let confirmQuitKey = "confirmQuit"
    static let defaultWarnBeforeQuit = true
    static let defaultConfirmQuitMode = QuitConfirmationMode.always

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        confirmQuitMode(defaults: defaults) != .never
    }

    static func shouldShowConfirmation(
        isQuitWarningConfirmed: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldShowConfirmation(
            isQuitWarningConfirmed: isQuitWarningConfirmed,
            hasDirtyWorkspaces: true,
            buildFlavor: .current,
            defaults: defaults
        )
    }

    static func shouldShowConfirmation(
        isQuitWarningConfirmed: Bool,
        hasDirtyWorkspaces: Bool,
        buildFlavor: BuildFlavor,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !isQuitWarningConfirmed else { return false }
        guard buildFlavor != .dev else { return false }

        switch confirmQuitMode(defaults: defaults) {
        case .always:
            return true
        case .dirtyOnly:
            return hasDirtyWorkspaces
        case .never:
            return false
        }
    }

    static func confirmQuitMode(defaults: UserDefaults = .standard) -> QuitConfirmationMode {
        if let rawValue = defaults.string(forKey: confirmQuitKey),
           let mode = QuitConfirmationMode(rawValue: rawValue) {
            return mode
        }
        if defaults.object(forKey: warnBeforeQuitKey) == nil {
            return defaultConfirmQuitMode
        }
        return defaults.bool(forKey: warnBeforeQuitKey) ? .always : .never
    }

    static func setMode(_ mode: QuitConfirmationMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: confirmQuitKey)
        defaults.set(mode != .never, forKey: warnBeforeQuitKey)
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        setMode(isEnabled ? .always : .never, defaults: defaults)
    }
}

nonisolated enum QuitConfirmationMode: String, CaseIterable, Sendable {
    case always
    case dirtyOnly = "dirty-only"
    case never

    var localizedSettingsTitle: String {
        switch self {
        case .always:
            return String(localized: "settings.app.confirmQuit.always", defaultValue: "Always")
        case .dirtyOnly:
            return String(localized: "settings.app.confirmQuit.dirtyOnly", defaultValue: "Dirty Only")
        case .never:
            return String(localized: "settings.app.confirmQuit.never", defaultValue: "Never")
        }
    }
}

nonisolated enum BuildFlavor: String, Sendable {
    case dev
    case nightly
    case stable

    static var current: BuildFlavor {
        let bundle = Bundle.main
        return detect(
            bundleNames: [
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                ProcessInfo.processInfo.processName,
            ].compactMap { $0 },
            bundleIdentifier: bundle.bundleIdentifier
        )
    }

    static func detect(bundleName: String?, bundleIdentifier: String?) -> BuildFlavor {
        detect(bundleNames: [bundleName].compactMap { $0 }, bundleIdentifier: bundleIdentifier)
    }

    static func detect(bundleNames: [String], bundleIdentifier: String?) -> BuildFlavor {
        if bundleNames.contains(where: containsDevToken) {
            return .dev
        }

        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if SocketControlSettings.isDebugLikeBundleIdentifier(normalizedBundleIdentifier) {
            return .dev
        }
        if normalizedBundleIdentifier == "com.cmuxterm.app.nightly"
            || normalizedBundleIdentifier?.hasPrefix("com.cmuxterm.app.nightly.") == true {
            return .nightly
        }
        if bundleNames.contains(where: containsNightlyToken) {
            return .nightly
        }
        return .stable
    }

    private static func containsDevToken(_ name: String) -> Bool {
        containsToken("DEV", in: name)
    }

    private static func containsNightlyToken(_ name: String) -> Bool {
        containsToken("NIGHTLY", in: name)
    }

    private static func containsToken(_ token: String, in name: String) -> Bool {
        name
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { String($0) == token }
    }
}

enum CloseTabWarningSettings {
    static let warnBeforeClosingTabKey = "warnBeforeClosingTabShortcut"
    static let defaultWarnBeforeClosingTab = true
    static let warnBeforeClosingTabXButtonKey = "warnBeforeClosingTabXButton"
    static let defaultWarnBeforeClosingTabXButton = false
    static let hideTabCloseButtonKey = "hideTabCloseButton"
    static let defaultHideTabCloseButton = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: warnBeforeClosingTabKey) == nil {
            return defaultWarnBeforeClosingTab
        }
        return defaults.bool(forKey: warnBeforeClosingTabKey)
    }

    static func warnsBeforeClosingTabXButton(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: warnBeforeClosingTabXButtonKey) == nil {
            return defaultWarnBeforeClosingTabXButton
        }
        return defaults.bool(forKey: warnBeforeClosingTabXButtonKey)
    }

    static func hidesTabCloseButton(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hideTabCloseButtonKey) == nil {
            return defaultHideTabCloseButton
        }
        return defaults.bool(forKey: hideTabCloseButtonKey)
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: warnBeforeClosingTabKey)
    }
}

enum CloseTabConfirmationPolicy {
    enum Source: Equatable {
        case shortcut
        case tabCloseButton
    }

    enum Decision: Equatable {
        case closeImmediately
        case confirmBeforeClosing
    }

    static func decision(
        requiresConfirmation: Bool,
        source: Source,
        defaults: UserDefaults = .standard
    ) -> Decision {
        let shouldConfirm: Bool
        switch source {
        case .shortcut:
            shouldConfirm = requiresConfirmation && CloseTabWarningSettings.isEnabled(defaults: defaults)
        case .tabCloseButton:
            shouldConfirm = CloseTabWarningSettings.warnsBeforeClosingTabXButton(defaults: defaults)
                || (requiresConfirmation && CloseTabWarningSettings.isEnabled(defaults: defaults))
        }

        guard shouldConfirm else {
            return .closeImmediately
        }
        return .confirmBeforeClosing
    }

    static func shouldConfirm(
        requiresConfirmation: Bool,
        source: Source,
        defaults: UserDefaults = .standard
    ) -> Bool {
        decision(
            requiresConfirmation: requiresConfirmation,
            source: source,
            defaults: defaults
        ) == .confirmBeforeClosing
    }
}

enum CommandPaletteRenameSelectionSettings {
    static let selectAllOnFocusKey = "commandPalette.renameSelectAllOnFocus"
    static let defaultSelectAllOnFocus = true

    static func selectAllOnFocusEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: selectAllOnFocusKey) == nil {
            return defaultSelectAllOnFocus
        }
        return defaults.bool(forKey: selectAllOnFocusKey)
    }
}

enum CommandPaletteSwitcherSearchSettings {
    static let searchAllSurfacesKey = "commandPalette.switcherSearchAllSurfaces"
    static let defaultSearchAllSurfaces = false

    static func searchAllSurfacesEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: searchAllSurfacesKey) == nil {
            return defaultSearchAllSurfaces
        }
        return defaults.bool(forKey: searchAllSurfacesKey)
    }
}

enum ClaudeCodeIntegrationSettings {
    static let hooksEnabledKey = "claudeCodeHooksEnabled"
    static let defaultHooksEnabled = true
    static let customClaudePathKey = "claudeCodeCustomClaudePath"

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }

    static func customClaudePath(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: customClaudePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

enum AgentSubagentNotificationSettings {
    static let suppressNotificationsKey = "suppressSubagentNotifications"
    static let defaultSuppressNotifications = true
    static let environmentKey = "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"

    static func suppressNotifications(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: suppressNotificationsKey) == nil {
            return defaultSuppressNotifications
        }
        return defaults.bool(forKey: suppressNotificationsKey)
    }
}

enum CursorIntegrationSettings {
    static let hooksEnabledKey = "cursorHooksEnabled"
    static let defaultHooksEnabled = true

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }
}

enum GeminiIntegrationSettings {
    static let hooksEnabledKey = "geminiHooksEnabled"
    static let defaultHooksEnabled = true

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }
}

enum WelcomeSettings {
    static let shownKey = "cmuxWelcomeShown"
}

enum TelemetrySettings {
    static let sendAnonymousTelemetryKey = "sendAnonymousTelemetry"
    static let defaultSendAnonymousTelemetry = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: sendAnonymousTelemetryKey) == nil {
            return defaultSendAnonymousTelemetry
        }
        return defaults.bool(forKey: sendAnonymousTelemetryKey)
    }

    // Freeze telemetry enablement once per launch. Settings changes apply on next restart.
    static let enabledForCurrentLaunch = isEnabled()
}

enum CmdClickMarkdownRouteSettings {
    static let key = "openMarkdownInCmuxViewer"
    static let defaultValue = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    /// Cheap extension check. Safe to call off the main thread before any
    /// filesystem probe so remote/non-markdown paths can be filtered early.
    static func isMarkdownPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "mkd" || ext == "mdx"
    }

    static func shouldRoute(path: String, defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(defaults: defaults),
              isMarkdownPath(path) else { return false }
        // Match the `markdown.open` socket path: only route real, readable
        // files. Rejects FIFOs, device nodes, sockets, symlinks to non-regular
        // targets, and permission-denied paths so the viewer never opens into
        // an unavailable state.
        return CmdClickSupportedFileRouteSettings.isReadableRegularFile(path: path)
    }
}

enum CmdClickSupportedFileRouteSettings {
    static let key = "openSupportedFilesInCmux"
    static let didChangeNotification = Notification.Name("cmux.cmdClickSupportedFileRouteDidChange")
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        return defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(enabled, forKey: key)
        notifyDidChange(notificationCenter: notificationCenter)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }

    static func shouldRoute(path: String, defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(defaults: defaults) else { return false }
        return isReadableRegularFile(path: path)
    }

    static func isReadableRegularFile(path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard FileManager.default.isReadableFile(atPath: resolved),
              let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              (attrs[.type] as? FileAttributeType) == .typeRegular else {
            return false
        }
        return true
    }
}

enum PreferredEditorSettings {
    static let key = "preferredEditorCommand"

    /// Returns the configured editor command, or nil to use system default.
    static func resolvedCommand(defaults: UserDefaults = .standard) -> String? {
        guard let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else {
            return nil
        }
        return stored
    }

    /// Open a file path with the user's preferred editor, falling back to system default.
    static func open(_ url: URL) {
        if CmuxUITestCapture.appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_PATH",
            line: url.path
        ) {
            return
        }

        guard let command = resolvedCommand() else {
            NSWorkspace.shared.open(url)
            return
        }
        let path = url.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(shellQuote(path))"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Check exit status on a background thread; fall back on failure
            // (e.g. command not found exits 127 but /bin/sh itself succeeds)
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            }
        } catch {
            NSWorkspace.shared.open(url)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum CmuxUITestCapture {
    static func appendLineIfConfigured(envKey: String, line: String) -> Bool {
        guard let url = configuredURL(for: envKey) else { return false }
        appendLine(line, to: url)
        return true
    }

    static func mutateJSONObjectIfConfigured(
        envKey: String,
        _ update: (inout [String: Any]) -> Void
    ) -> Bool {
        guard let url = configuredURL(for: envKey) else { return false }
        mutateJSONObject(at: url, update)
        return true
    }

    private static func configuredURL(for envKey: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        guard let rawPath = env[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawPath)
    }

    private static func appendLine(_ line: String, to url: URL) {
        ensureParentDirectory(for: url)
        let payload = (line + "\n").data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } catch {
                if let existing = try? Data(contentsOf: url) {
                    var combined = existing
                    combined.append(payload)
                    try? combined.write(to: url, options: .atomic)
                } else {
                    try? payload.write(to: url, options: .atomic)
                }
            }
            return
        }

        try? payload.write(to: url, options: .atomic)
    }

    private static func mutateJSONObject(
        at url: URL,
        _ update: (inout [String: Any]) -> Void
    ) {
        ensureParentDirectory(for: url)
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        update(&payload)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func ensureParentDirectory(for url: URL) {
        let directory = url.deletingLastPathComponent()
        guard !directory.path.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

enum CmuxRuntimeDebugCapture {
    private struct Configuration {
        let baseURL: URL
        let token: String
        let sessionID: String
    }

    private static let configuration: Configuration? = {
        let env = ProcessInfo.processInfo.environment
        guard let baseURLString = env["CMUX_RUNTIME_DEBUG_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let baseURL = URL(string: baseURLString),
              let token = env["CMUX_RUNTIME_DEBUG_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let sessionID = env["CMUX_RUNTIME_DEBUG_SESSION_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }
        return Configuration(baseURL: baseURL, token: token, sessionID: sessionID)
    }()

    private static let lock = NSLock()
    private static var sequence: Int = 0

    static func logIfConfigured(
        hypothesisID: String,
        source: String,
        name: String,
        expected: String? = nil,
        actual: String? = nil,
        data: [String: Any] = [:]
    ) {
        guard let configuration else { return }

        var payload: [String: Any] = [
            "session_id": configuration.sessionID,
            "hypothesis_id": hypothesisID,
            "service": "cmux-macos",
            "source": source,
            "name": name,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "mono_ms": ProcessInfo.processInfo.systemUptime * 1000,
            "seq": nextSequence(),
            "data": data
        ]
        if let expected {
            payload["expected"] = expected
        }
        if let actual {
            payload["actual"] = actual
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let requestBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/logs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.token, forHTTPHeaderField: "X-Debug-Token")
        request.httpBody = requestBody

        URLSession.shared.dataTask(with: request).resume()
    }

    private static func nextSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        return sequence
    }
}
func openCmuxSettingsFileInEditor() {
    let url = KeyboardShortcutSettings.settingsFileStore.settingsFileURLForEditing()
    PreferredEditorSettings.open(url)
}

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
                            subtitle: String(localized: "settings.app.openMarkdownInCmuxViewer.subtitle", defaultValue: "When supported file routing is on, Cmd-clicking Markdown files opens the rendered cmux markdown viewer instead of the generic file preview.")
                        ) {
                            Toggle("", isOn: $openMarkdownInCmuxViewer)
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

private struct SurfaceResumeApprovalSettingsCard: View {
    @State private var recordCount = 0

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("terminal.resumeCommands"),
                String(localized: "settings.terminal.resumeCommands", defaultValue: "Resume Commands"),
                subtitle: String(
                    localized: "settings.terminal.resumeCommands.subtitle",
                    defaultValue: "Review signed command prefixes that can restore non-agent terminal surfaces."
                ),
                controlWidth: 170,
                searchAnchorID: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "resume-commands")
            ) {
                HStack(spacing: 8) {
                    Text(String(format: "%d", recordCount))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)

                    Button(String(localized: "settings.settingsJSON.openButton", defaultValue: "Open")) {
                        openCmuxSettingsFileInEditor()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: SurfaceResumeApprovalStore.didChangeNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        recordCount = SurfaceResumeApprovalStore.loadRecords().count
    }
}

struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, -2)
    }
}

private struct AuthSettingsRow: View {
    @ObservedObject var authManager: AuthManager

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 12)
            if authManager.isLoading || authManager.isRestoringSession {
                ProgressView().controlSize(.small)
            }
            Button(action: buttonAction) {
                Text(buttonTitle)
            }
            .controlSize(.small)
            .disabled(authManager.isLoading || authManager.isRestoringSession)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var titleText: String {
        if authManager.isAuthenticated {
            if let email = authManager.currentUser?.primaryEmail, !email.isEmpty {
                return email
            }
            return String(
                localized: "settings.account.signedIn.title",
                defaultValue: "Signed in"
            )
        }
        return String(
            localized: "settings.account.signedOut.title",
            defaultValue: "Not signed in"
        )
    }

    private var subtitleText: String? {
        if authManager.isAuthenticated {
            return authManager.currentUser?.displayName
        }
        return String(
            localized: "settings.account.signedOut.subtitle",
            defaultValue: "Sign in with your cmux account to enable sync across devices."
        )
    }

    private var buttonTitle: String {
        if authManager.isAuthenticated {
            return String(
                localized: "settings.account.signOut",
                defaultValue: "Sign Out"
            )
        }
        return String(
            localized: "settings.account.signIn",
            defaultValue: "Sign In…"
        )
    }

    private func buttonAction() {
        if authManager.isAuthenticated {
            Task { @MainActor in
                await authManager.signOut()
            }
        } else {
            authManager.beginSignIn()
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: NSColor.controlBackgroundColor).opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color(nsColor: NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
    }
}

struct SettingsCardRow<Trailing: View>: View {
    let configurationReview: SettingsConfigurationReview
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat?
    let searchAnchorID: String?
    @ViewBuilder let trailing: Trailing

    init(
        configurationReview: SettingsConfigurationReview,
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat? = nil,
        searchAnchorID: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        configurationReview.validate()
        self.configurationReview = configurationReview
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self.searchAnchorID = searchAnchorID
        self.trailing = trailing()
    }

    private var searchAnchorIDs: [String] { searchAnchorID.map { [$0] } ?? configurationReview.searchAnchorIDs }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let controlWidth {
                    trailing
                        .frame(width: controlWidth, alignment: .trailing)
                } else {
                    trailing
                }
            }
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchAnchors(searchAnchorIDs)
    }
}

private struct SettingsPickerRow<SelectionValue: Hashable, PickerContent: View, ExtraTrailing: View>: View {
    let configurationReview: SettingsConfigurationReview
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat
    @Binding var selection: SelectionValue
    let pickerContent: PickerContent
    let extraTrailing: ExtraTrailing
    let accessibilityId: String?

    init(
        configurationReview: SettingsConfigurationReview,
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat,
        selection: Binding<SelectionValue>,
        accessibilityId: String? = nil,
        @ViewBuilder content: () -> PickerContent,
        @ViewBuilder extraTrailing: () -> ExtraTrailing
    ) {
        configurationReview.validate()
        self.configurationReview = configurationReview
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self._selection = selection
        self.pickerContent = content()
        self.extraTrailing = extraTrailing()
        self.accessibilityId = accessibilityId
    }

    var body: some View {
        SettingsCardRow(configurationReview: configurationReview, title, subtitle: subtitle, controlWidth: controlWidth) {
            HStack(spacing: 6) {
                Picker("", selection: $selection) {
                    pickerContent
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .applyIf(accessibilityId != nil) { $0.accessibilityIdentifier(accessibilityId!) }
                extraTrailing
            }
        }
    }
}

extension SettingsPickerRow where ExtraTrailing == EmptyView {
    init(
        configurationReview: SettingsConfigurationReview,
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat,
        selection: Binding<SelectionValue>,
        accessibilityId: String? = nil,
        @ViewBuilder content: () -> PickerContent
    ) {
        self.init(configurationReview: configurationReview, title, subtitle: subtitle, controlWidth: controlWidth, selection: selection, accessibilityId: accessibilityId, content: content) {
            EmptyView()
        }
    }
}

enum SettingsConfigurationReview: Equatable {
    case settingsFile([String])
    case settingsOnly
    case action
    case debugOnly

    static func json(_ paths: String...) -> Self {
        .settingsFile(paths)
    }

    var searchAnchorIDs: [String] {
        guard case .settingsFile(let paths) = self else { return [] }
        return paths.compactMap(SettingsSearchIndex.anchorID(forSettingsPath:))
    }

    func validate(file: StaticString = #fileID, line: UInt = #line) {
        guard case .settingsFile(let paths) = self else { return }
        let unknownPaths = paths.filter { !CmuxSettingsFileStore.supportedSettingsJSONPaths.contains($0) }
        precondition(
            unknownPaths.isEmpty,
            "Unknown cmux.json settings path(s): \(unknownPaths.joined(separator: ", "))",
            file: file,
            line: line
        )
    }
}

private extension View {
    @ViewBuilder
    func applyIf(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: NSColor.separatorColor).opacity(0.5))
            .frame(height: 1)
    }
}

private struct ThemeWindowThumbnail: View {
    let isDark: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                // Wallpaper background
                if isDark {
                    LinearGradient(
                        colors: [Color(red: 0.1, green: 0.1, blue: 0.3), Color(red: 0.05, green: 0.05, blue: 0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * 0.5))
                        path.addQuadCurve(to: CGPoint(x: width, y: height), control: CGPoint(x: width * 0.5, y: height * 0.2))
                        path.addLine(to: CGPoint(x: width, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: 0))
                    }
                    .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.2, blue: 0.6).opacity(0.5), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.6, green: 0.8, blue: 0.95), Color(red: 0.2, green: 0.4, blue: 0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * 0.5))
                        path.addQuadCurve(to: CGPoint(x: width, y: height), control: CGPoint(x: width * 0.5, y: height * 0.2))
                        path.addLine(to: CGPoint(x: width, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: 0))
                    }
                    .fill(LinearGradient(colors: [Color(red: 0.8, green: 0.9, blue: 1.0).opacity(0.6), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }

                // Menu bar
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "applelogo")
                            .font(.system(size: max(height * 0.08, 6)))
                            .foregroundColor(isDark ? .white : .black)
                            .opacity(0.8)
                        Spacer()
                    }
                    .padding(.horizontal, max(width * 0.04, 4))
                    .frame(height: max(height * 0.12, 8))
                    .background(.ultraThinMaterial)
                    Spacer()
                }

                // Back window
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(isDark ? Color(white: 0.2) : Color(white: 0.9))
                        .frame(height: max(height * 0.15, 8))
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(isDark ? Color(white: 0.15) : Color(white: 0.98))
                        RoundedRectangle(cornerRadius: max(width * 0.02, 2), style: .continuous)
                            .fill(Color.accentColor)
                            .frame(height: max(height * 0.12, 6))
                            .padding(max(width * 0.04, 4))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: max(width * 0.04, 4), style: .continuous))
                .frame(width: width * 0.65, height: height * 0.45)
                .shadow(color: .black.opacity(isDark ? 0.4 : 0.15), radius: 4, x: 0, y: 2)
                .offset(x: -width * 0.08, y: -height * 0.1)

                // Front window with traffic lights
                VStack(spacing: 0) {
                    ZStack {
                        Rectangle()
                            .fill(isDark ? Color(white: 0.18) : Color(white: 0.92))
                        HStack(spacing: max(width * 0.025, 2)) {
                            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: max(width * 0.04, 3))
                            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: max(width * 0.04, 3))
                            Circle().fill(Color(red: 0.15, green: 0.79, blue: 0.25)).frame(width: max(width * 0.04, 3))
                            Spacer()
                        }
                        .padding(.horizontal, max(width * 0.04, 4))
                    }
                    .frame(height: max(height * 0.18, 10))
                    Rectangle()
                        .fill(isDark ? Color(white: 0.1) : .white)
                }
                .clipShape(RoundedRectangle(cornerRadius: max(width * 0.05, 5), style: .continuous))
                .shadow(color: .black.opacity(isDark ? 0.5 : 0.2), radius: 6, x: 0, y: 3)
                .frame(width: width * 0.75, height: height * 0.55)
                .offset(x: width * 0.12, y: height * 0.2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct ThemePickerRow: View {
    let configurationReview: SettingsConfigurationReview
    let selectedMode: String
    let onSelect: (AppearanceMode) -> Void

    private let thumbWidth: CGFloat = 76
    private let thumbHeight: CGFloat = 50

    init(
        configurationReview: SettingsConfigurationReview,
        selectedMode: String,
        onSelect: @escaping (AppearanceMode) -> Void
    ) {
        configurationReview.validate()
        self.configurationReview = configurationReview
        self.selectedMode = selectedMode
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(localized: "settings.app.theme", defaultValue: "Theme"))
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(AppearanceMode.visibleCases) { mode in
                    let isSelected = selectedMode == mode.rawValue
                    Button {
                        onSelect(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if mode == .system {
                                    ZStack {
                                        ThemeWindowThumbnail(isDark: false)
                                            .mask(
                                                GeometryReader { geo in
                                                    Rectangle()
                                                        .frame(width: geo.size.width / 2, height: geo.size.height)
                                                        .position(x: geo.size.width / 4, y: geo.size.height / 2)
                                                }
                                            )
                                        ThemeWindowThumbnail(isDark: true)
                                            .mask(
                                                GeometryReader { geo in
                                                    Rectangle()
                                                        .frame(width: geo.size.width / 2, height: geo.size.height)
                                                        .position(x: geo.size.width * 0.75, y: geo.size.height / 2)
                                                }
                                            )
                                        GeometryReader { geo in
                                            Rectangle()
                                                .fill(Color.primary.opacity(0.15))
                                                .frame(width: 1, height: geo.size.height)
                                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                                        }
                                    }
                                } else {
                                    ThemeWindowThumbnail(isDark: mode == .dark)
                                }
                            }
                            .frame(width: thumbWidth, height: thumbHeight)

                            Text(mode.displayName)
                                .font(.system(size: 10))
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundColor(isSelected ? .primary : .secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchAnchors(configurationReview.searchAnchorIDs)
    }
}

private struct AppIconPickerRow: View {
    let configurationReview: SettingsConfigurationReview
    let selectedMode: String
    let onSelect: (AppIconMode) -> Void

    private let iconSize: CGFloat = 48
    private let autoIconSize: CGFloat = 36

    init(
        configurationReview: SettingsConfigurationReview,
        selectedMode: String,
        onSelect: @escaping (AppIconMode) -> Void
    ) {
        configurationReview.validate()
        self.configurationReview = configurationReview
        self.selectedMode = selectedMode
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "settings.app.appIcon", defaultValue: "App Icon"))
                    .font(.system(size: 13, weight: .medium))
                Text(String(localized: "settings.app.appIcon.subtitle", defaultValue: "Dock and app switcher"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(AppIconMode.allCases) { mode in
                    let isSelected = selectedMode == mode.rawValue
                    Button {
                        onSelect(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if mode == .automatic {
                                    ZStack {
                                        Image("AppIconLight")
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: autoIconSize, height: autoIconSize)
                                            .clipShape(RoundedRectangle(cornerRadius: autoIconSize * 0.22, style: .continuous))
                                            .offset(x: -10)
                                        Image("AppIconDark")
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: autoIconSize, height: autoIconSize)
                                            .clipShape(RoundedRectangle(cornerRadius: autoIconSize * 0.22, style: .continuous))
                                            .offset(x: 10)
                                    }
                                    .frame(width: iconSize, height: iconSize)
                                } else {
                                    Image(mode.imageName ?? "AppIconLight")
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: iconSize, height: iconSize)
                                        .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
                                }
                            }

                            Text(mode.displayName)
                                .font(.system(size: 10))
                                .foregroundColor(isSelected ? .primary : .secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchAnchors(configurationReview.searchAnchorIDs)
    }
}

private struct GlobalHotkeySection: View {
    @AppStorage(SystemWideHotkeySettings.enabledKey) private var isEnabled = SystemWideHotkeySettings.defaultEnabled
    @State private var shortcut = KeyboardShortcutSettings.shortcut(for: SystemWideHotkeySettings.action)
    @State private var isManagedBySettingsFile = SystemWideHotkeySettings.isManagedBySettingsFile()

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                isEnabled = newValue
            }
        )
    }

    private var enableSubtitle: String {
        if isEnabled {
            return String(
                localized: "settings.globalHotkey.enable.subtitleOn",
                defaultValue: "Press the shortcut from any app to show or hide all cmux windows."
            )
        }
        return String(
            localized: "settings.globalHotkey.enable.subtitleOff",
            defaultValue: "Turn this on to show or hide all cmux windows from any app."
        )
    }

    var body: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey"))
            .accessibilityIdentifier("SettingsGlobalHotkeySection")
            .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .globalHotkey))

        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.globalHotkey.enable", defaultValue: "Enable System-Wide Hotkey"),
                subtitle: enableSubtitle,
                searchAnchorID: SettingsSearchIndex.settingID(for: .globalHotkey, idSuffix: "enable-hotkey")
            ) {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsGlobalHotkeyToggle")
            }

            SettingsCardDivider()

            ShortcutRecorderSettingsControl(
                action: SystemWideHotkeySettings.action,
                shortcut: $shortcut,
                subtitle: isManagedBySettingsFile ? KeyboardShortcutSettings.settingsFileManagedSubtitle(for: SystemWideHotkeySettings.action) : nil,
                isDisabled: isManagedBySettingsFile
            )
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityIdentifier("SettingsGlobalHotkeyRecorder")
                .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .globalHotkey, idSuffix: "shortcut"))
        }
        .onChange(of: shortcut) { _, newValue in
            KeyboardShortcutSettings.setShortcut(newValue, for: SystemWideHotkeySettings.action)
        }
        .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
            syncFromDefaults()
        }

        SettingsCardNote(
            String(
                localized: "settings.globalHotkey.note",
                defaultValue: "Use Command, Option, or Control with another key. No extra macOS permission is required."
            )
        )
            .accessibilityIdentifier("SettingsGlobalHotkeyNote")
    }

    private func syncFromDefaults() {
        let latestShortcut = KeyboardShortcutSettings.shortcut(for: SystemWideHotkeySettings.action)
        let latestManagedState = SystemWideHotkeySettings.isManagedBySettingsFile()
        if latestShortcut != shortcut {
            shortcut = latestShortcut
        }
        if latestManagedState != isManagedBySettingsFile {
            isManagedBySettingsFile = latestManagedState
        }
    }
}

private struct SettingsWindowRootView: View {
    @State private var draftState = SettingsDraftState()
    @State private var windowReference = WeakSettingsWindowReference()
    @State private var shouldRenderSettingsContent = true

    var body: some View {
        Group {
            if shouldRenderSettingsContent {
                SettingsRootView(draftState: draftState)
            } else {
                Color.clear
                    .frame(
                        minWidth: SettingsWindowPresenter.minimumSize.width,
                        minHeight: SettingsWindowPresenter.minimumSize.height
                    )
            }
        }
        .background(WindowAccessor { window in
            windowReference.window = window
            SettingsWindowPresenter.configure(window: window)
            setContentVisibility(!window.isMiniaturized)
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard isObservedWindow(notification.object) else { return }
            setContentVisibility(false)
            windowReference.window = nil
        }
    }

    private func isObservedWindow(_ object: Any?) -> Bool {
        guard
            let notificationWindow = object as? NSWindow,
            let window = windowReference.window
        else {
            return false
        }
        return notificationWindow === window
    }

    private func setContentVisibility(_ isVisible: Bool) {
        guard shouldRenderSettingsContent != isVisible else { return }
        shouldRenderSettingsContent = isVisible
    }
}

@MainActor
private final class WeakSettingsWindowReference {
    weak var window: NSWindow?
}

@MainActor
@Observable
final class SettingsDraftState {
    var browserInsecureHTTPAllowlistDraft = BrowserInsecureHTTPSettings.defaultAllowlistText
    var browserInsecureHTTPAllowlistSyncedValue = BrowserInsecureHTTPSettings.defaultAllowlistText
    var socketPasswordDraft = ""
    var settingsColumnVisibility: NavigationSplitViewVisibility = .all
    var settingsSearchText = ""

    func syncBrowserInsecureHTTPAllowlistFromSavedValue(_ savedValue: String) {
        if browserInsecureHTTPAllowlistDraft == browserInsecureHTTPAllowlistSyncedValue {
            browserInsecureHTTPAllowlistDraft = savedValue
        }
        browserInsecureHTTPAllowlistSyncedValue = savedValue
    }
}

private struct SettingsRootView: View {
    @Bindable var draftState: SettingsDraftState
    @SceneStorage("selectedSettingsSection") private var selectedSectionRaw = SettingsNavigationTarget.account.rawValue
    @SceneStorage("selectedSettingsSidebarEntry") private var selectedSidebarEntryID = SettingsSearchIndex.defaultSelectionID

    private var selectedSection: SettingsNavigationTarget {
        SettingsNavigationTarget(rawValue: selectedSectionRaw) ?? .account
    }

    private var sidebarEntries: [SettingsSearchEntry] {
        SettingsSearchIndex.entries(matching: draftState.settingsSearchText)
    }

    private var isSearching: Bool {
        !draftState.settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sidebarSelection: Binding<String> {
        Binding(
            get: { selectedSidebarEntryID },
            set: { selectSidebarEntry($0) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $draftState.settingsColumnVisibility) {
            List(selection: sidebarSelection) {
                if sidebarEntries.isEmpty {
                    Text(String(localized: "settings.search.noResults", defaultValue: "No Results"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sidebarEntries) { entry in
                        SettingsSidebarEntryRow(entry: entry)
                            .tag(entry.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
            .searchable(
                text: $draftState.settingsSearchText,
                placement: .sidebar,
                prompt: Text(String(localized: "settings.search.prompt", defaultValue: "Search"))
            )
            .navigationSplitViewColumnWidth(210)
        } detail: {
            SettingsView(draftState: draftState)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: SettingsWindowPresenter.minimumSize.width, minHeight: SettingsWindowPresenter.minimumSize.height)
        .onChange(of: draftState.settingsSearchText) { _, newValue in
            guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            selectedSidebarEntryID = SettingsSearchIndex.sectionID(for: selectedSection)
        }
        .onAppear {
            if let target = SettingsWindowPresenter.consumePendingNavigationTarget() {
                navigate(to: target, postRequest: true)
            } else {
                navigate(to: selectedSection, postRequest: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notificationName)) { notification in
            guard let target = SettingsNavigationRequest.target(from: notification) else { return }
            let selectedEntry = SettingsSearchIndex.entry(withID: selectedSidebarEntryID)
            let shouldPreserveSearchSelection = isSearching && selectedEntry?.target == target
            navigate(to: target, preferSectionSelection: !shouldPreserveSearchSelection, postRequest: false)
        }
    }

    private func selectSidebarEntry(_ entryID: String) {
        guard let entry = SettingsSearchIndex.entry(withID: entryID) else { return }
        selectedSidebarEntryID = entry.id
        selectedSectionRaw = entry.target.rawValue
        SettingsNavigationRequest.post(entry.target, anchorID: entry.id, highlight: isSearching)
    }

    private func navigate(
        to target: SettingsNavigationTarget,
        preferSectionSelection: Bool = true,
        postRequest: Bool
    ) {
        selectedSectionRaw = target.rawValue
        if preferSectionSelection {
            selectedSidebarEntryID = SettingsSearchIndex.sectionID(for: target)
        }
        if postRequest {
            SettingsNavigationRequest.post(target)
        }
    }
}

private struct SettingsSidebarEntryRow: View {
    let entry: SettingsSearchEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(1)

                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
