import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxPanes
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSettings
import CmuxSettingsUI
import CmuxWorkspaces
import CmuxTestSupport
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers
import CmuxTerminal

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
    @State private var browserFocusModeMenuRevision = 0
    @StateObject var focusHistoryMenuInvalidator = FocusHistoryMenuInvalidator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    private var browserToolbarAccessorySpacing: Int {
        BrowserToolbarAccessorySpacingDebugSettings.resolved(browserToolbarAccessorySpacingRaw)
    }

    init() {
        // Gather settings package dependencies once. The runtime itself
        // is assigned after the saved language override below, because
        // it owns localized search-index text for the process lifetime.
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
        let languageSettingsStore = LanguageSettingsStore(defaults: .standard)
        languageSettingsStore.applyLanguageOverride(languageSettingsStore.storedLanguage)
        StartupBreadcrumbLog.append("app.init.language.applied")
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
        StartupBreadcrumbLog.append("app.init.settingsRuntime.created")

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

    private static func terminateForMissingLaunchTag() -> Never {
        let message = "error: refusing to launch untagged cmux DEV; start with ./scripts/reload.sh --tag <name> (or set CMUX_TAG for test harnesses)"
        fputs("\(message)\n", stderr)
        fflush(stderr)
        NSLog("%@", message)
        Darwin.exit(64)
    }

    private static func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let currentResourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap { String(cString: $0) }
        if let resolvedResourcesDir = resolvedGhosttyResourcesDirectory(
            currentValue: currentResourcesDir,
            bundleResourceURL: Bundle.main.resourceURL,
            fileManager: fileManager
        ) {
            setenv("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir, 1)
        }

        if getenv("TERMINFO") == nil,
           let terminfoURL = Bundle.main.resourceURL?.appendingPathComponent("terminfo"),
           fileManager.fileExists(atPath: terminfoURL.path) {
            setenv("TERMINFO", terminfoURL.path, 1)
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

            prependEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: dataDir,
                defaultValue: "/usr/local/share:/usr/share"
            )
            prependEnvPathIfMissing("MANPATH", path: manDir)
        }
    }

    static func resolvedGhosttyResourcesDirectory(
        currentValue: String?,
        bundleResourceURL: URL?,
        ghosttyAppResources: String = "/Applications/Ghostty.app/Contents/Resources/ghostty",
        fileManager: FileManager = .default
    ) -> String? {
        let bundledGhosttyURL = bundleResourceURL?.appendingPathComponent("ghostty")
        // Tagged cmux builds may inherit GHOSTTY_RESOURCES_DIR from another running
        // cmux instance. Prefer this app's bundled resources when they are present.
        if let bundledGhosttyURL,
           fileManager.fileExists(atPath: bundledGhosttyURL.path),
           fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
            return bundledGhosttyURL.path
        }

        if let currentValue = currentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentValue.isEmpty,
           fileManager.fileExists(atPath: currentValue) {
            return currentValue
        }

        if fileManager.fileExists(atPath: ghosttyAppResources) {
            return ghosttyAppResources
        }

        if let bundledGhosttyURL,
           fileManager.fileExists(atPath: bundledGhosttyURL.path) {
            return bundledGhosttyURL.path
        }

        return nil
    }

    private static func prependEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        if path.isEmpty { return }
        var current = getenv(key).flatMap { String(cString: $0) } ?? ""
        if current.isEmpty, let defaultValue {
            current = defaultValue
        }
        if current.split(separator: ":").contains(Substring(path)) {
            return
        }
        let updated = current.isEmpty ? path : "\(path):\(current)"
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
                .settingsRuntime(settingsRuntime)
                .cmuxFontMagnificationEnvironment()
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
                InstallUpdateMenuItem(model: appDelegate.updateViewModel, actions: appDelegate)
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
                Menu("Show Update Error…") {
                    ForEach(DebugUpdateErrorScenario.allCases, id: \.self) { scenario in
                        Button(scenario.menuTitle) {
                            appDelegate.updateViewModel.debugShowUpdateError(scenario)
                        }
                    }
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

                CanvasDebugMenuButtons(
                    workspace: activeTabManager.selectedWorkspace,
                    openStressWorkspacesWithLoadedSurfaces: {
                        appDelegate.openDebugStressWorkspacesWithLoadedSurfaces(nil)
                    }
                )

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
                    Button(
                        String(
                            localized: "debug.menu.devWindowDisplay",
                            defaultValue: "Dev Window Display…"
                        )
                    ) {
                        DevWindowDisplayDebugWindowController.shared.show()
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
                        AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow()
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

                splitCommandButton(title: String(localized: "menu.file.newBrowserWorkspace", defaultValue: "New Browser Workspace"), shortcut: menuShortcut(for: .newBrowserWorkspace)) {
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.performNewBrowserWorkspaceAction(
                            tabManager: activeTabManager,
                            debugSource: "menu.newBrowserWorkspace"
                        )
                    } else if BrowserAvailabilitySettings.isEnabled() {
                        // Last-resort fallback for a missing AppDelegate; keep
                        // the browser-availability gate identical to the
                        // shared action path.
                        activeTabManager.addWorkspace(initialSurface: .browser)
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
                .cmuxFontMagnificationEnvironment()
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
                .cmuxFontMagnificationEnvironment()
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

            let browserFocusModeMenu = browserFocusModeMenuSnapshot
            Button(browserFocusModeMenu.title) {
                if !activeTabManager.toggleBrowserFocusModeForFocusedBrowser(reason: "viewMenu") {
                    NSSound.beep()
                }
            }
            .disabled(!browserFocusModeMenu.canToggle)

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

            splitCommandButton(title: String(localized: "menu.view.toggleCanvasLayout", defaultValue: "Toggle Canvas Layout"), shortcut: menuShortcut(for: .toggleCanvasLayout)) {
                guard let workspace = activeTabManager.selectedWorkspace else { return }
                CanvasActionExecutor(workspace: workspace).perform(.toggleLayout)
            }

            splitCommandButton(title: String(localized: "menu.view.canvasOverview", defaultValue: "Canvas Overview"), shortcut: menuShortcut(for: .canvasOverview)) {
                guard let workspace = activeTabManager.selectedWorkspace else { return }
                CanvasActionExecutor(workspace: workspace).perform(.toggleOverview)
            }

            splitCommandButton(title: String(localized: "menu.view.canvasTidy", defaultValue: "Tidy Canvas"), shortcut: menuShortcut(for: .canvasTidy)) {
                guard let workspace = activeTabManager.selectedWorkspace else { return }
                CanvasActionExecutor(workspace: workspace).perform(.alignment(.tidy))
            }

            Divider()

            // Numbered workspace selection (9 = last workspace)
            ForEach(1...9, id: \.self) { number in
                // `menuShortcut(for:)` already returns `.unbound` when the action
                // carries a configured `shortcuts.when` clause, so a context-gated
                // workspace shortcut takes the no-key-equivalent branch and the
                // gated keyDown handler owns dispatch (issue #5189).
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
        appDelegate.installReloadConfigurationMenuItemAction()
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

    private var browserFocusModeMenuSnapshot: (title: String, canToggle: Bool) {
        let _ = browserFocusModeMenuRevision
        let panel = activeTabManager.focusedBrowserPanel
        return (
            title: panel?.isBrowserFocusModeActive == true
                ? String(localized: "menu.view.exitBrowserFocusMode", defaultValue: "Exit Browser Focus Mode")
                : String(localized: "menu.view.enterBrowserFocusMode", defaultValue: "Enter Browser Focus Mode"),
            canToggle: panel?.canToggleBrowserFocusMode == true
        )
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

    private func dispatchReloadConfigurationMenuCommand() {
        NSApp.sendAction(
            #selector(AppDelegate.reloadConfigurationMenuItem(_:)),
            to: appDelegate,
            from: nil
        )
    }

    private func closePanelOrWindow() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let window, cmuxWindowShouldOwnCloseShortcut(window) { window.performClose(nil); return }
        if appDelegate.closeFocusedDockPanelForCommand(preferredWindow: window) { return }
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
        AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow()
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
    "cmux.defaultTerminalRegistrationError",
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
    "cmux.devWindowDisplay",
    "cmux.mobilePairingWindow",
]

/// Returns whether the given window should handle the standard close shortcut
/// as a standalone auxiliary window instead of routing it through workspace or
/// panel-close behavior.
func cmuxWindowShouldOwnCloseShortcut(_ window: NSWindow?) -> Bool {
    guard let identifier = window?.identifier?.rawValue else { return false }
    return cmuxAuxiliaryWindowIdentifiers.contains(identifier)
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
        sidebarBranchVerticalLayout=\(boolValue(defaults, key: SidebarCatalogSection().branchVerticalLayout.userDefaultsKey, fallback: SidebarCatalogSection().branchVerticalLayout.defaultValue))
        sidebarBranchDirectoryStacked=\(boolValue(defaults, key: SidebarCatalogSection().stackBranchDirectory.userDefaultsKey, fallback: SidebarCatalogSection().stackBranchDirectory.defaultValue))
        sidebarPathLastSegmentOnly=\(boolValue(defaults, key: SidebarCatalogSection().pathLastSegmentOnly.userDefaultsKey, fallback: SidebarCatalogSection().pathLastSegmentOnly.defaultValue))
        sidebarActiveTabIndicatorStyle=\(stringValue(defaults, key: WorkspaceColorsCatalogSection().indicatorStyle.userDefaultsKey, fallback: WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue))
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
private final class DebugWindowControlsWindowController: ReleasingWindowController {
    static let shared = DebugWindowControlsWindowController()

    override func makeWindow() -> NSWindow {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.debugWindowControls")
        window.center()
        window.contentView = NSHostingView(rootView: DebugWindowControlsView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
    }
}

private struct DebugWindowControlsView: View {
    @AppStorage(WorkspaceColorsCatalogSection().indicatorStyle.userDefaultsKey)
    private var sidebarActiveTabIndicatorStyle = WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconNameKey) private var browserDevToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconColorKey) private var browserDevToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue

    private var selectedDevToolsIconOption: BrowserDevToolsIconOption {
        BrowserDevToolsIconOption(rawValue: browserDevToolsIconNameRaw) ?? BrowserDevToolsButtonDebugSettings.defaultIcon
    }

    private var selectedDevToolsColorOption: BrowserDevToolsIconColorOption {
        BrowserDevToolsIconColorOption(rawValue: browserDevToolsIconColorRaw) ?? BrowserDevToolsButtonDebugSettings.defaultColor
    }

    private var selectedSidebarActiveTabIndicatorStyle: WorkspaceIndicatorStyle {
        WorkspaceIndicatorStyle.decodeFromUserDefaults(sidebarActiveTabIndicatorStyle)
            ?? WorkspaceColorsCatalogSection().indicatorStyle.defaultValue
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
                    .cmuxFont(.headline)

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
                            AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow()
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
                            AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow()
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
                            ForEach(WorkspaceIndicatorStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("Reset Indicator Style") {
                            sidebarActiveTabIndicatorStyle = WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue
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
                                .cmuxFont(size: 12, weight: .medium)
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
                            .cmuxFont(.caption)
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

private final class BrowserImportHintDebugWindowController: ReleasingWindowController {
    static let shared = BrowserImportHintDebugWindowController()

    override func makeWindow() -> NSWindow {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserImportHintDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserImportHintDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
    }
}

private final class BrowserProfilePopoverDebugWindowController: ReleasingWindowController {
    static let shared = BrowserProfilePopoverDebugWindowController()

    override func makeWindow() -> NSWindow {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.browserProfilePopoverDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BrowserProfilePopoverDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
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
                .cmuxFont(.headline)

                Text(
                    String(
                        localized: "debug.browserProfilePopover.note",
                        defaultValue: "Tune the profile popover padding live while comparing it against the browser toolbar menu."
                    )
                )
                .cmuxFont(.caption)
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
                .cmuxFont(.caption)
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
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .cmuxFont(size: 10, weight: .semibold)
                        .frame(width: 12, alignment: .center)
                    Text(String(localized: "browser.profile.default", defaultValue: "Default"))
                        .cmuxFont(size: 12)
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
                .cmuxFont(size: 12)

            Text(String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"))
                .cmuxFont(size: 12)
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
                .cmuxFont(.caption)
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
                    .cmuxFont(.headline)

                Text("Try lighter blank-tab import surfaces and dismissal states without touching the permanent Browser settings home.")
                    .cmuxFont(.caption)
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
                            .cmuxFont(.caption)
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
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                        Text("Settings status: \(settingsStatusTitle(presentation.settingsStatus))")
                            .cmuxFont(.caption)
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
                    .cmuxFont(.caption)
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

private final class AboutWindowController: ReleasingWindowController {
    static let shared = AboutWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        window.center()
        window.contentView = NSHostingView(rootView: AboutPanelView())
        AppDelegate.shared?.aboutTitlebarDebugStore.applyCurrentOptions(to: window, for: .about)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        let window = managedWindow()
        AppDelegate.shared?.aboutTitlebarDebugStore.applyCurrentOptions(to: window, for: .about)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

private final class AcknowledgmentsWindowController: ReleasingWindowController {
    static let shared = AcknowledgmentsWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "about.licenses.windowTitle", defaultValue: "Third-Party Licenses")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.licenses")
        window.center()
        window.contentView = NSHostingView(rootView: AcknowledgmentsView())
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showManagedWindow(centerWhenHidden: false)
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
                .cmuxFont(.body, design: .monospaced)
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
                .cmuxFont(.headline)

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
                                    .cmuxFont(size: 13, weight: .medium)
                                Text(styleDescription(style))
                                    .cmuxFont(size: 11)
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
                    .cmuxFont(size: 11, weight: .medium)
                Text("Row: \(Int(currentStyle.rowHeight))pt, Indent: \(Int(currentStyle.indentation))pt, Icon: \(Int(currentStyle.iconSize))pt")
                    .cmuxFont(size: 11, design: .monospaced)
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
}

private final class FileExplorerStyleDebugWindowController: ReleasingWindowController {
    static let shared = FileExplorerStyleDebugWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.fileExplorerStyleDebug")
        window.center()
        window.contentView = NSHostingView(rootView: FileExplorerStyleDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showManagedWindow()
    }
}

private final class SidebarDebugWindowController: ReleasingWindowController {
    static let shared = SidebarDebugWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sidebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SidebarDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showManagedWindow()
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
                        .cmuxFont(.title)
                        .bold()
                    Text(String(localized: "about.description", defaultValue: "A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS."))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .cmuxFont(.caption)
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
                        .cmuxFont(.caption)
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
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults().opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults().hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @AppStorage(SidebarCatalogSection().branchVerticalLayout.userDefaultsKey)
    private var sidebarBranchVerticalLayout = SidebarCatalogSection().branchVerticalLayout.defaultValue
    @AppStorage(SidebarCatalogSection().stackBranchDirectory.userDefaultsKey)
    private var sidebarBranchDirectoryStacked = SidebarCatalogSection().stackBranchDirectory.defaultValue
    @AppStorage(SidebarCatalogSection().pathLastSegmentOnly.userDefaultsKey)
    private var sidebarPathLastSegmentOnly = SidebarCatalogSection().pathLastSegmentOnly.defaultValue
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(WorkspaceColorsCatalogSection().indicatorStyle.userDefaultsKey)
    private var sidebarActiveTabIndicatorStyle = WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue
    @AppStorage("sidebarSelectionColorHex") private var sidebarSelectionColorHex: String?

    private var selectedSidebarIndicatorStyle: WorkspaceIndicatorStyle {
        WorkspaceIndicatorStyle.decodeFromUserDefaults(sidebarActiveTabIndicatorStyle)
            ?? WorkspaceColorsCatalogSection().indicatorStyle.defaultValue
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
                    .cmuxFont(.headline)

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
                                .cmuxFont(.caption)
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
                                .cmuxFont(.caption)
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
                            .cmuxFont(.caption)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Active Workspace Indicator") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Style", selection: sidebarIndicatorStyleSelection) {
                            ForEach(WorkspaceIndicatorStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }

                        ColorPicker(String(localized: "sidebar.debug.selectionColor", defaultValue: "Selection Color"), selection: selectionColorBinding, supportsOpacity: false)

                        if sidebarSelectionColorHex != nil {
                            Button(String(localized: "sidebar.debug.resetSelectionColor", defaultValue: "Reset to Default")) {
                                sidebarSelectionColorHex = nil
                            }
                            .cmuxFont(.caption)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Workspace Metadata") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Render branch list vertically", isOn: $sidebarBranchVerticalLayout)
                        Text("When enabled, each branch appears on its own line in the sidebar.")
                            .cmuxFont(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button("Reset Tint") {
                        sidebarTintOpacity = SidebarTintDefaults().opacity
                        sidebarTintHex = SidebarTintDefaults().hex
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
                        sidebarActiveTabIndicatorStyle = WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue
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

private final class MenuBarExtraDebugWindowController: ReleasingWindowController {
    static let shared = MenuBarExtraDebugWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.menubarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: MenuBarExtraDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showManagedWindow()
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
                    .cmuxFont(.headline)

                GroupBox("Preview Count") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Override unread count", isOn: $previewEnabled)

                        Stepper(value: $previewCount, in: 0...99) {
                            HStack {
                                Text("Unread Count")
                                Spacer()
                                Text("\(previewCount)")
                                    .cmuxFont(.caption)
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
                    .cmuxFont(.caption)
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
                .cmuxFont(.caption)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func applyLiveUpdate() {
        AppDelegate.shared?.refreshMenuBarExtraForDebug()
    }
}

// MARK: - Split Button Layout Debug Window

private final class SplitButtonLayoutDebugWindowController: ReleasingWindowController {
    static let shared = SplitButtonLayoutDebugWindowController()

    override func makeWindow() -> NSWindow {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.splitButtonLayoutDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SplitButtonLayoutDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
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
                .cmuxFont(.headline)

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
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Tab Bar Backdrop Lab Window

private final class TabBarBackdropLabWindowController: ReleasingWindowController {
    static let shared = TabBarBackdropLabWindowController()

    override func makeWindow() -> NSWindow {
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

        return window
    }

    func show() {
        showManagedWindow(orderFrontRegardless: true)
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
        WindowChromeColorResolver().separatorColor(forChromeBackground: terminalColor)
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
                        .cmuxFont(.headline)
                    Text(String(localized: "debug.tabBarBackdropLab.subtitle", defaultValue: "Live Bonsplit tab bars with overflow tabs under the split buttons. The window background is transparent."))
                        .cmuxFont(.caption)
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
                .cmuxFont(.caption, monospacedDigit: true)
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
                    .cmuxFont(.caption, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(variant.detail)
                    .cmuxFont(.caption2)
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
                .cmuxFont(.caption2, weight: .medium)
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
                .cmuxFont(.caption2, weight: .bold)
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
            .cmuxFont(size: 11, design: .monospaced)
            .padding(10)
        }
    }
}

// MARK: - Background Debug Window

private final class BackgroundDebugWindowController: ReleasingWindowController {
    static let shared = BackgroundDebugWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.backgroundDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BackgroundDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showManagedWindow()
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
                    .cmuxFont(.headline)

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
                                .cmuxFont(.caption)
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
                    .cmuxFont(.caption)
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
        AppWindowChromeComposition().backdropController.updateGlassTint(to: window, color: tintColor)
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

private final class StartupAppearanceDebugWindowController: ReleasingWindowController {
    static let shared = StartupAppearanceDebugWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
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
        window.identifier = NSUserInterfaceItemIdentifier("cmux.startupAppearanceDebug")
        window.center()
        window.contentView = NSHostingView(rootView: StartupAppearanceDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showManagedWindow()
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
                    .cmuxFont(.headline)

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
                            .cmuxFont(.caption)
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
                                .cmuxFont(.caption, design: .monospaced)
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
                            .cmuxFont(.caption)
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
        if let appDelegate = AppDelegate.shared {
            appDelegate.reloadConfiguration(
                source: "debug.startupAppearancePreview",
                reloadSettingsFromFile: false
            )
        } else {
            GhosttyApp.shared.reloadConfiguration(
                source: "debug.startupAppearancePreview",
                reloadSettingsFromFile: false
            )
        }
        lastAppliedProfile = selectedProfile
        lastAppliedAppearance = selectedAppearance
    }

    private func restoreRealStartup() {
        selectedProfile = .realUserConfig
        selectedAppearance = .stored
        applyAppearance(.stored)
        GhosttyStartupAppearancePreviewState.profile = .realUserConfig
        GhosttyConfig.invalidateLoadCache()
        if let appDelegate = AppDelegate.shared {
            appDelegate.reloadConfiguration(
                source: "debug.startupAppearanceRestore",
                reloadSettingsFromFile: false
            )
        } else {
            GhosttyApp.shared.reloadConfiguration(
                source: "debug.startupAppearanceRestore",
                reloadSettingsFromFile: false
            )
        }
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
        .cmuxFont(.callout)
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
        let resetApplicationIconImage: () -> Void
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
                resetApplicationIconImage: {
                    // Setting nil restores the bundle's layered AppIcon so macOS
                    // can apply light/dark/tinted/clear treatments natively.
                    NSApplication.shared.applicationIconImage = nil
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
            // Defer to the bundle's layered AppIcon (Icon Composer .icon) so macOS
            // can apply light/dark/tinted/clear icon treatments natively. Assigning
            // a runtime NSImage via applicationIconImage replaces the layered icon
            // with a flat bitmap and silently disables Tinted/Clear on macOS 26.
            environment.stopAppearanceObservation()
            environment.resetApplicationIconImage()
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

enum TelemetrySettings {
    // Launch-frozen telemetry enablement: read once at process start so settings
    // changes apply on next restart. The persisted key, default, and read logic
    // live in `CmuxSettings` (`AppCatalogSection().sendAnonymousTelemetry`) as the
    // single source of truth; this anchor only freezes that read for the lifetime
    // of the launch.
    static let enabledForCurrentLaunch = AppCatalogSection().sendAnonymousTelemetry.value(in: .standard)
}

@MainActor
func openCmuxSettingsFileInEditor() {
    let url = KeyboardShortcutSettings.settingsFileStore.settingsFileURLForEditing()
    PreferredEditorService(defaults: .standard).open(url)
}
