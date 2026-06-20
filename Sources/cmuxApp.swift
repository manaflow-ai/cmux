import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxPanes
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSettings
import CmuxSettingsUI
import CmuxWorkspaces
import CmuxTerminalCore
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
///
/// `CmuxMain` plus ``cmuxApp`` are the executable target's permanent
/// composition-root residue. The god-file decomposition drained the settings,
/// app-shell, debug-tooling, workspace, and notification subsystems out of
/// `cmuxApp.swift` into packages; what remains here is, by design, the code that
/// cannot move down per the executable-target boundary (CONVENTIONS §6):
///
/// - **Constraint 1 (the `@main` App stays in the executable):** ``cmuxApp``'s
///   `body`/`Scene`/`Commands`/`MenuBarExtra` trees are SwiftUI result-builder
///   bodies on the `@main` `App`. A `some Scene`/`some Commands`
///   `@SceneBuilder`/`@CommandsBuilder` body is a member of the App type, and a
///   lower package cannot declare or extend the `@main` App type, so these trees
///   are irreducible residue. They stay thin: each menu/scene item only places a
///   button, reads a resolved snapshot (e.g. `WorkspaceCommandMenuState`,
///   `NotificationMenuSnapshot`), and forwards to an injected package
///   coordinator or to `AppDelegate`. No domain logic lives in the bodies.
/// - **Composition root:** ``cmuxApp/init()`` is the single place the object
///   graph is assembled (the `SettingsRuntime`, `MacAuthComposition`, secret
///   migrations, the `TabManager` state object, appearance/socket bootstrap),
///   then injected into scenes and into `AppDelegate.configure(...)`. This is the
///   intended end state, not debt.
/// - **Menu-builder satellites:** `cmuxApp+EqualizeSplitsMenu.swift` and
///   `cmuxApp+HistoryMenu.swift` are `cmuxApp` extensions for the same reason
///   (constraint 1). They are pure `@CommandsBuilder`/`@ViewBuilder` shims that
///   forward to package coordinators (`CmuxWorkspaces` workspace/focus-history
///   commands, the closed-item history model); their logic already lives in the
///   packages.
/// - **Accepted DEBUG-lab residue (deferred, not constraint-1):** the
///   `#if DEBUG` lab/content views still in this file
///   (`DebugWindowControlsView`, `TabBarBackdropLabView`, `BackgroundDebugView`,
///   `StartupAppearanceDebugView`, `FileExplorerStyleDebugView`) are app-coupled
///   SwiftUI content injected into the package-owned window shells in
///   `CmuxAppKitSupportUI`. They read live app-target state (`GhosttyApp`,
///   `Workspace`, `AppDelegate`, app-target settings enums), so they are
///   documented residue pending the dedicated content-inversion slice; they are
///   not part of the irreducible composition-root shape.
/// - **Root anchors:** the `BuildFlavor` typealias (the value type lives in
///   `CmuxFoundation`) and the file-scope `telemetrySettings` constant (the one
///   process-wide `TelemetrySettingsStore`, read via the
///   `TelemetrySettingsReading` seam) are composition-root anchors for global
///   callers with nowhere to inject a dependency.
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
        let languageSettingsStore = LanguageSettingsStore(defaults: .standard)
        languageSettingsStore.applyLanguageOverride(languageSettingsStore.storedLanguage)
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
            SocketControlPasswordStore().migrateLegacyKeychainPasswordIfNeeded(defaults: defaults)
            StartupBreadcrumbLog.append("app.init.keychainMigration.complete")
        }
        SidebarAppearanceDefaultsMigration(defaults: defaults).migrate()
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
                    KeyboardShortcutSettings.openSettingsFileInEditor()
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
                        AppDelegate.shared?.debugWindowsCoordinator.showBackgroundDebug()
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
                        AppDelegate.shared?.debugWindowsCoordinator.showBrowserImportHintDebug()
                    }
                    Button(
                        String(
                            localized: "debug.menu.browserProfilePopoverDebug",
                            defaultValue: "Browser Profile Popover Debug…"
                        )
                    ) {
                        AppDelegate.shared?.debugWindowsCoordinator.showBrowserProfilePopoverDebug()
                    }
                    Button("Debug Window Controls…") {
                        AppDelegate.shared?.debugWindowsCoordinator.showDebugWindowControls()
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
                        AppDelegate.shared?.debugWindowsCoordinator.showMenuBarExtraDebug()
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
                        AppDelegate.shared?.debugWindowsCoordinator.showSidebarDebug()
                    }
                    Button("Split Button Layout Debug…") {
                        AppDelegate.shared?.debugWindowsCoordinator.showSplitButtonLayoutDebugWindow()
                    }
                    Button(
                        String(
                            localized: "debug.menu.tabBarBackdropLab",
                            defaultValue: "Tab Bar Backdrop Lab…"
                        )
                    ) {
                        AppDelegate.shared?.debugWindowsCoordinator.showTabBarBackdropLab()
                    }
                    Button("File Explorer Style Debug…") {
                        AppDelegate.shared?.debugWindowsCoordinator.showFileExplorerStyleDebug()
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

        WindowGroup(String(localized: "settings.title", defaultValue: "Settings"), id: SettingsWindowPresenter.windowID) {
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
        appDelegate.debugWindowsCoordinator.showAbout()
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

    @ViewBuilder
    private func workspaceCommandMenuContent(manager: TabManager) -> some View {
        // The workspace-command logic (selected-workspace index math, move/close
        // tab-list slicing, per-item enablement, pin/mark labels, window-move
        // targets) lives in `WorkspaceCommandCoordinator` (CmuxWorkspaces). The
        // menu shell stays here because a SwiftUI `@CommandsBuilder` body cannot
        // move into a package; it only places buttons and reads the resolved
        // `WorkspaceCommandMenuState`.
        let commands = manager.workspaceCommands
        let state = commands.menuState()

        Button(state.pinToggleLabel) {
            commands.toggleSelectedWorkspacePinned()
        }
        .disabled(!state.pinToggleEnabled)

        Button(String(localized: "menu.view.renameWorkspace", defaultValue: "Rename Workspace…")) {
            commands.renameSelectedWorkspace()
        }
        .disabled(!state.hasSelectedWorkspace)

        Button(String(localized: "menu.view.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
            commands.editSelectedWorkspaceDescription()
        }
        .disabled(!state.hasSelectedWorkspace)

        if state.selectedWorkspaceHasCustomTitle {
            Button(String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")) {
                commands.clearSelectedWorkspaceCustomName()
            }
        }

        Divider()

        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            commands.moveSelectedWorkspace(by: -1)
        }
        .disabled(!state.canMoveUp)

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            commands.moveSelectedWorkspace(by: 1)
        }
        .disabled(!state.canMoveDown)

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")) {
            commands.moveSelectedWorkspaceToTop()
        }
        .disabled(!state.canMoveToTop)

        Menu(String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                commands.moveSelectedWorkspaceToNewWindow()
            }
            .disabled(!state.hasSelectedWorkspace)

            if !state.windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(state.windowMoveTargets) { target in
                Button(target.label) {
                    commands.moveSelectedWorkspace(toWindow: target.windowId)
                }
                .disabled(target.isCurrentWindow || !state.hasSelectedWorkspace)
            }
        }
        .disabled(!state.hasSelectedWorkspace)

        Divider()

        Button(String(localized: "menu.file.closeWorkspace", defaultValue: "Close Workspace")) {
            commands.closeSelectedWorkspace()
        }
        .disabled(!state.hasSelectedWorkspace)

        Button(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")) {
            commands.closeOtherSelectedWorkspacePeers()
        }
        .disabled(!state.canCloseOthers)

        Button(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")) {
            commands.closeSelectedWorkspacesBelow()
        }
        .disabled(!state.canCloseBelow)

        Button(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")) {
            commands.closeSelectedWorkspacesAbove()
        }
        .disabled(!state.canCloseAbove)

        Divider()

        Button(String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read")) {
            commands.markSelectedWorkspaceRead()
        }
        .disabled(!state.canMarkRead)

        Button(String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")) {
            commands.markSelectedWorkspaceUnread()
        }
        .disabled(!state.canMarkUnread)
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
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut(window.identifier?.rawValue) {
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
        AppDelegate.shared?.debugWindowsCoordinator.showDebugWindowControls()
        AppDelegate.shared?.debugWindowsCoordinator.showBrowserImportHintDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showBrowserProfilePopoverDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow()
        TitlebarLayoutDebugWindowController.shared.show()
        AppDelegate.shared?.debugWindowsCoordinator.showSidebarDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showBackgroundDebug()
        StartupAppearanceDebugWindowController.shared.show()
        AppDelegate.shared?.debugWindowsCoordinator.showMenuBarExtraDebug()
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


// The "Debug Window Controls" panel's window/lifecycle shell now lives in
// CmuxAppKitSupportUI (`DebugWindowControlsWindowController`), presented via
// `AppDelegate.shared?.debugWindowsCoordinator.showDebugWindowControls()`. This
// view remains in the app target because it opens roughly a dozen other
// app-target debug window controllers and reads several app-target settings
// types; it is injected into the package controller as the panel's content view.
#if DEBUG
struct DebugWindowControlsView: View {
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
                    .font(.headline)

                GroupBox("Open") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Browser Import Hint Debug…") {
                            AppDelegate.shared?.debugWindowsCoordinator.showBrowserImportHintDebug()
                        }
                        Button(
                            String(
                                localized: "debug.menu.browserProfilePopoverDebug",
                                defaultValue: "Browser Profile Popover Debug…"
                            )
                        ) {
                            AppDelegate.shared?.debugWindowsCoordinator.showBrowserProfilePopoverDebug()
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
                            AppDelegate.shared?.debugWindowsCoordinator.showSidebarDebug()
                        }
                        Button("Background Debug…") {
                            AppDelegate.shared?.debugWindowsCoordinator.showBackgroundDebug()
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
                            AppDelegate.shared?.debugWindowsCoordinator.showMenuBarExtraDebug()
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
                            AppDelegate.shared?.debugWindowsCoordinator.showTabBarBackdropLab()
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
                            AppDelegate.shared?.debugWindowsCoordinator.showDebugWindowControls()
                            AppDelegate.shared?.debugWindowsCoordinator.showBrowserImportHintDebug()
                            AppDelegate.shared?.debugWindowsCoordinator.showBrowserProfilePopoverDebug()
                            AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow()
                            TitlebarLayoutDebugWindowController.shared.show()
                            AppDelegate.shared?.debugWindowsCoordinator.showSidebarDebug()
                            AppDelegate.shared?.debugWindowsCoordinator.showBackgroundDebug()
                            BonsplitTabBarDebugWindowController.shared.show()
                            StartupAppearanceDebugWindowController.shared.show()
                            AppDelegate.shared?.debugWindowsCoordinator.showMenuBarExtraDebug()
                            PDFPreviewChromeDebugWindowController.shared.show()
                            AppDelegate.shared?.debugWindowsCoordinator.showTabBarBackdropLab()
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
                            copyAllDebugConfig()
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

    // Copies the combined sidebar/titlebar/background/menu-bar/browser-devtools
    // snapshot via the package `DebugWindowConfigSnapshotService`. The service owns
    // the generic UserDefaults-coercion helpers and the pasteboard plumbing; the
    // combined payload text stays here because it interpolates app-target settings
    // enums and catalog-section keys, so it is supplied through the injected
    // closure (the service is captured to reuse its coercion helpers).
    private func copyAllDebugConfig() {
        var service: DebugWindowConfigSnapshotService?
        let built = DebugWindowConfigSnapshotService(defaults: .standard) {
            guard let service else { return "" }
            return DebugWindowControlsView.combinedDebugConfigPayload(using: service)
        }
        service = built
        built.copyCombinedToPasteboard()
    }

    private static func combinedDebugConfigPayload(
        using service: DebugWindowConfigSnapshotService
    ) -> String {
        let defaults = service.defaults
        let sidebarPayload = """
        sidebarPreset=\(service.stringValue(key: "sidebarPreset", fallback: SidebarPresetOption.nativeSidebar.rawValue))
        sidebarMaterial=\(service.stringValue(key: "sidebarMaterial", fallback: SidebarMaterialOption.sidebar.rawValue))
        sidebarBlendMode=\(service.stringValue(key: "sidebarBlendMode", fallback: SidebarBlendModeOption.withinWindow.rawValue))
        sidebarState=\(service.stringValue(key: "sidebarState", fallback: SidebarStateOption.followWindow.rawValue))
        sidebarBlurOpacity=\(String(format: "%.2f", service.doubleValue(key: "sidebarBlurOpacity", fallback: 1.0)))
        sidebarTintHex=\(service.stringValue(key: "sidebarTintHex", fallback: "#000000"))
        sidebarTintHexLight=\(service.stringValue(key: "sidebarTintHexLight", fallback: "(nil)"))
        sidebarTintHexDark=\(service.stringValue(key: "sidebarTintHexDark", fallback: "(nil)"))
        sidebarTintOpacity=\(String(format: "%.2f", service.doubleValue(key: "sidebarTintOpacity", fallback: 0.18)))
        sidebarCornerRadius=\(String(format: "%.1f", service.doubleValue(key: "sidebarCornerRadius", fallback: 0.0)))
        sidebarBranchVerticalLayout=\(service.boolValue(key: SidebarCatalogSection().branchVerticalLayout.userDefaultsKey, fallback: SidebarCatalogSection().branchVerticalLayout.defaultValue))
        sidebarBranchDirectoryStacked=\(service.boolValue(key: SidebarCatalogSection().stackBranchDirectory.userDefaultsKey, fallback: SidebarCatalogSection().stackBranchDirectory.defaultValue))
        sidebarPathLastSegmentOnly=\(service.boolValue(key: SidebarCatalogSection().pathLastSegmentOnly.userDefaultsKey, fallback: SidebarCatalogSection().pathLastSegmentOnly.defaultValue))
        sidebarActiveTabIndicatorStyle=\(service.stringValue(key: WorkspaceColorsCatalogSection().indicatorStyle.userDefaultsKey, fallback: WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue))
        sidebarDevBuildBannerVisible=\(service.boolValue(key: DevBuildBannerDebugSettings.sidebarBannerVisibleKey, fallback: DevBuildBannerDebugSettings.defaultShowSidebarBanner))
        sidebarMinimumWidth=\(String(format: "%.1f", SessionPersistencePolicy.resolvedMinimumSidebarWidth(defaults: defaults)))
        """

        let backgroundPayload = """
        bgGlassEnabled=\(service.boolValue(key: "bgGlassEnabled", fallback: false))
        bgGlassMaterial=\(service.stringValue(key: "bgGlassMaterial", fallback: "hudWindow"))
        bgGlassTintHex=\(service.stringValue(key: "bgGlassTintHex", fallback: "#000000"))
        bgGlassTintOpacity=\(String(format: "%.2f", service.doubleValue(key: "bgGlassTintOpacity", fallback: 0.03)))
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
}
#endif

// The About and Acknowledgments windows (`AboutWindowController`,
// `AcknowledgmentsWindowController`) plus their content views (`AboutPanelView`,
// `AcknowledgmentsView`, `AboutPropertyRow`, `AboutVisualEffectBackground`) now
// live in `CmuxAppKitSupportUI`. `DebugWindowsCoordinator` owns their lifecycle
// (replacing the former `.shared` singletons); the app target injects the
// localized strings and forwards `showAboutPanel()` to
// `debugWindowsCoordinator.showAbout()`.

// MARK: - File Explorer Style Debug

struct FileExplorerStyleDebugView: View {
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

// MARK: - Menu Bar Extra Debug Window
//
// The Menu Bar Extra Debug panel (`MenuBarExtraDebugView`) and its
// `MenuBarIconDebugSettings`/`MenuBarBadgeRenderConfig` tuning now live in
// `CmuxAppKitSupportUI`; `DebugWindowsCoordinator` mounts the package view directly
// and the app target injects only the live menu-bar icon refresh closure.

// MARK: - Tab Bar Backdrop Lab Window
//
// The Tab Bar Backdrop Lab views (`TabBarBackdropLabView` and its sample
// subviews) and the `TabBarBackdropLabVariant` value type now live in
// `CmuxAppKitSupportUI`. The app target snapshots its backdrop tuning into a
// `TabBarBackdropLabInputs` value and injects the package view through
// `DebugWindowsCoordinator.tabBarBackdropLabContentProvider` (see `AppDelegate`).

// MARK: - Background Debug Window
//
// The Background Debug panel (`BackgroundDebugView`) now lives in
// `CmuxAppKitSupportUI`. `DebugWindowsCoordinator` mounts the package view
// directly; the app target injects only the live glass-tint apply closure (the
// main-window lookup plus the window-chrome composition) through
// `DebugWindowsCoordinator.backgroundDebugContentProvider` (see `AppDelegate`).

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

// `BuildFlavor` now lives in `CmuxFoundation` (pure `Sendable` value type). This
// typealias keeps the app-target spelling `BuildFlavor` byte-identical at every
// call site.
typealias BuildFlavor = CmuxFoundation.BuildFlavor

// Composition-root anchor for app-target global callers (`sentry*` helpers,
// `PostHogAnalytics`, scroll-lag capture, launch breadcrumbs) with no injected
// dependency to thread the store through. Exactly one `TelemetrySettingsStore`
// is constructed here at process start; its read logic and launch-freeze live
// in `CmuxSettings`. The binding is lazy and thread-safe like the `static let`
// it replaced, so the freeze point is identical. Callers depend on the
// `TelemetrySettingsReading` seam, never the storage mechanism.
let telemetrySettings: any TelemetrySettingsReading = TelemetrySettingsStore(defaults: .standard)
