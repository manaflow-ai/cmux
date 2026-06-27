import AppKit
import CmuxAppKitSupportUI
import CmuxBrowser
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
/// - **DEBUG-lab content fully inverted:** the Startup Appearance debug panel's
///   SwiftUI content (`StartupAppearanceDebugView`) now lives in
///   `CmuxAppKitSupportUI`; its app couplings invert behind the
///   `StartupAppearanceReloading` seam (conformed app-side by
///   `StartupAppearanceDebugReloader`) with localized strings resolved app-side
///   (`DebugWindowControlsContentProvider.startupAppearanceDebugStrings`). No `#if DEBUG` content view
///   remains in this file.
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

    /// App-owned orchestrator for the socket-control server lifecycle. Holds the
    /// composition-root `AppDelegate`; the `@AppStorage socketControlMode` trigger
    /// and its `.onChange` modifier stay in this App and forward the raw mode and
    /// the active `TabManager` to it.
    private let socketControlCoordinator: SocketControlCoordinator

    @State private var tabManager: TabManager
    // De-singletonization stage b73: this `@StateObject` is the composition-root
    // owner of the single `TerminalNotificationStore`. `AppDelegate.configure`
    // records it via `installCompositionRootInstance`, so the transitional
    // `TerminalNotificationStore.shared` accessor read by the tail call sites
    // resolves to this same object instead of a self-vivified `static let shared`.
    @StateObject var notificationStore = TerminalNotificationStore.shared
    // De-singletonization stage b73: `ClosedItemHistoryStore` no longer
    // self-vivifies an eager `static let shared`. The composition root
    // (`AppDelegate.closedItemHistory`, installed in
    // `applicationDidFinishLaunching`) owns the single instance; the transitional
    // ``ClosedItemHistoryStore/shared`` accessor used here for the history-menu
    // `@State` resolves to that same object, so the menu and the AppDelegate
    // call sites read one store.
    @State var closedItemHistoryStore = ClosedItemHistoryStore.shared
    @State private var sidebarState = SidebarState()
    // De-singletonization stage b76: this `@State` is the composition-root
    // owner of the single `KeyboardShortcutSettingsObserver`. `AppDelegate.configure`
    // records it via `installCompositionRootInstance`, so the transitional
    // `KeyboardShortcutSettingsObserver.shared` accessor read by the remaining view
    // sites resolves to this same object instead of a self-vivified `static let shared`.
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    // De-singletonization: this `@State` is the composition-root owner of the
    // single Task Manager window controller. It seeds from the transitional
    // `.shared` accessor (which self-vivifies the lazy instance) and is recorded
    // as the composition-root instance in `appDelegate.configure`, so the menu,
    // menu-bar extra, and command-palette call sites all reach this one object.
    @State private var taskManagerWindowController = TaskManagerWindowController.shared
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyle = TitlebarControlsStyle.classic.rawValue
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage(BrowserToolbarAccessorySpacingStore.key) private var browserToolbarAccessorySpacingRaw = BrowserToolbarAccessorySpacingStore.defaultSpacing
    @State private var browserFocusModeMenuRevision = 0
    @State var focusHistoryMenuInvalidator = FocusHistoryMenuInvalidator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    private var browserToolbarAccessorySpacing: Int {
        BrowserToolbarAccessorySpacingStore.resolved(browserToolbarAccessorySpacingRaw)
    }

    init() {
        // Build the settings container once. All injected dependencies
        // (the catalog, the two stores, the error log) live on this
        // single struct; nothing in the package or app references a
        // shared static.
        let settingsCatalog = SettingCatalog()
        let configFileURL = CmuxConfigLocation().userConfigFile
        // Bootstrap the secure secret store before any managed-config layer reads
        // `cmux.json`: relocate a pre-existing socket password out of the legacy
        // Application Support directory, derive the secret base directory,
        // construct the store, and lift any plaintext socket-control password out
        // of the config into the secure store (then scrub it). This App
        // initializer is the composition root, so it names the concrete
        // `FileManager.default` and `configFileURL` and injects them; the
        // sequencing lives in `SecretStoreBootstrap`.
        // See https://github.com/manaflow-ai/cmux/issues/5146.
        let secretStore = SecretStoreBootstrap(
            fileManager: .default,
            configFileURL: configFileURL
        ).configureSecretStore()
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

        GhosttyStartupEnvironment(bundleResourceURL: Bundle.main.resourceURL).configure()
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
        _tabManager = State(wrappedValue: TabManager())
        // Own the socket-control orchestrator at the composition root. It holds
        // only the `appDelegate` adaptor, but is constructed here — after every
        // other stored property is initialized — because reading the
        // `@NSApplicationDelegateAdaptor` `appDelegate` requires `self` to be
        // fully initialized.
        socketControlCoordinator = SocketControlCoordinator(appDelegate: appDelegate)
        StartupBreadcrumbLog.append("app.init.tabManager.complete")
        // Normalize the persisted socket mode and (for release builds) migrate the
        // legacy keychain password. Breadcrumb instrumentation stays app-side.
        SocketControlModeDefaultsMigration(
            defaults: defaults,
            bundleIdentifier: Bundle.main.bundleIdentifier
        ).migrate(
            willMigrateKeychainPassword: {
                StartupBreadcrumbLog.append("app.init.keychainMigration.begin")
            },
            didMigrateKeychainPassword: {
                StartupBreadcrumbLog.append("app.init.keychainMigration.complete")
            }
        )
        SidebarAppearanceDefaultsMigration(defaults: defaults).migrate()
        StartupBreadcrumbLog.append("app.init.sidebarDefaults.migrated")

        // UI tests depend on AppDelegate wiring happening even if SwiftUI view appearance
        // callbacks (e.g. `.onAppear`) are delayed or skipped.
        StartupBreadcrumbLog.append("app.init.delegate.configure.begin")
        appDelegate.configure(
            tabManager: tabManager,
            notificationStore: notificationStore,
            keyboardShortcutSettingsObserver: keyboardShortcutSettingsObserver,
            taskManagerWindowController: taskManagerWindowController,
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
                    socketControlCoordinator.apply(
                        rawMode: socketControlMode,
                        tabManager: activeTabManager
                    )
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
                    ConfigSourceEnvironment.live().openInTextEditor()
                }
                splitCommandButton(title: String(localized: "menu.app.reloadConfiguration", defaultValue: "Reload Configuration"), shortcut: menuShortcut(for: .reloadConfiguration)) {
                    dispatchReloadConfigurationMenuCommand()
                }
                Button(String(localized: "menu.app.makeDefaultTerminal", defaultValue: "Make cmux the Default Terminal")) {
                    AppDelegate.makeDefaultTerminal(debugSource: "menu.makeDefaultTerminal")
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

            notificationsCommands

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
                        AppDelegate.shared?.debugWindowsCoordinator.showBonsplitTabBarDebug()
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
                        AppDelegate.shared?.debugWindowsCoordinator.showDevWindowDisplayDebug()
                    }
                    Button("Feed Preview…") {
                        AppDelegate.shared?.debugWindowsCoordinator.showFeedPreview()
                    }
                    Button(
                        String(
                            localized: "debug.menu.feedTextEditorDebug",
                            defaultValue: "Feed Text Editor Lab…"
                        )
                    ) {
                        AppDelegate.shared?.debugWindowsCoordinator.showFeedTextEditorDebug()
                    }
                    Button(
                        String(
                            localized: "debug.menu.feedButtonStyleDebug",
                            defaultValue: "Feed Button Style Debug…"
                        )
                    ) {
                        AppDelegate.shared?.debugWindowsCoordinator.showFeedButtonStyleDebug()
                    }
                    Button(
                        String(
                            localized: "debug.menu.startupAppearanceDebug",
                            defaultValue: "Startup Appearance Debug…"
                        )
                    ) {
                        AppDelegate.shared?.debugWindowsCoordinator.showStartupAppearanceDebug()
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
                        AppDelegate.shared?.debugWindowsCoordinator.showTitlebarLayoutDebug()
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
                        AppDelegate.shared?.debugWindowsCoordinator.showPDFPreviewChromeDebug()
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
                    ForEach(BrowserToolbarAccessorySpacingStore.supportedValues, id: \.self) { spacing in
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
                taskManagerWindowController.show()
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
                        if let targetIndex = WorkspaceShortcutMapper(workspaceCount: manager.tabs.count).workspaceIndex(forDigit: number) {
                            manager.selectTab(at: targetIndex)
                        }
                    }
                } else {
                    Button(String(localized: "menu.view.workspace", defaultValue: "Workspace \(number)")) {
                        let manager = activeTabManager
                        if let targetIndex = WorkspaceShortcutMapper(workspaceCount: manager.tabs.count).workspaceIndex(forDigit: number) {
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

    private func bootstrapMainWindowScene() {
        appDelegate.scheduleInitialMainWindowBootstrap(debugSource: "swiftUIBootstrap")
        appDelegate.installReloadConfigurationMenuItemAction()
        applyAppearance()
    }

    func menuShortcut(for action: KeyboardShortcutSettings.Action) -> StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.menuShortcut(for: action)
    }

    private var browserFocusModeMenuSnapshot: (title: String, canToggle: Bool) {
        let _ = browserFocusModeMenuRevision
        let panel = activeTabManager.focusedBrowserPanel
        let state = BrowserFocusModeMenuState(
            isFocusModeActive: panel?.isBrowserFocusModeActive == true,
            canToggle: panel?.canToggleBrowserFocusMode == true
        )
        return (
            title: state.title == .exitBrowserFocusMode
                ? String(localized: "menu.view.exitBrowserFocusMode", defaultValue: "Exit Browser Focus Mode")
                : String(localized: "menu.view.enterBrowserFocusMode", defaultValue: "Enter Browser Focus Mode"),
            canToggle: state.canToggle
        )
    }

    var activeTabManager: TabManager {
        AppDelegate.shared?.activeTabManagerForCommands(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        ) ?? tabManager
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
        ShortcutCommandButton(
            title: title,
            keyEquivalent: shortcut.keyEquivalent,
            eventModifiers: shortcut.eventModifiers,
            action: action
        )
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

    func showNotificationsPopover() {
        AppDelegate.shared?.toggleNotificationsPopover(animated: false)
    }

#if DEBUG
    private func openAllDebugWindows() {
        AppDelegate.shared?.debugWindowsCoordinator.showDebugWindowControls()
        AppDelegate.shared?.debugWindowsCoordinator.showBrowserImportHintDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showBrowserProfilePopoverDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow()
        AppDelegate.shared?.debugWindowsCoordinator.showTitlebarLayoutDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showSidebarDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showBackgroundDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showStartupAppearanceDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showMenuBarExtraDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showPDFPreviewChromeDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showFeedPreview()
        AppDelegate.shared?.debugWindowsCoordinator.showFeedTextEditorDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showFeedButtonStyleDebug()
        AppDelegate.shared?.debugWindowsCoordinator.showBonsplitTabBarDebug()
    }
#endif
}


// The "Debug Window Controls" panel now lives entirely in CmuxAppKitSupportUI
// (`DebugWindowControlsView` + `DebugWindowControlsWindowController`), presented
// via `AppDelegate.shared?.debugWindowsCoordinator.showDebugWindowControls()`.
// The panel's content is app-coupled (it opens roughly a dozen other app-target
// debug windows, reads the app-target browser-devtools settings, and copies a
// combined config payload that interpolates app-target settings enums), so the
// app target injects the open-actions, the browser-devtools option rows, and the
// combined-config closure through `DebugWindowControlsContentProvider.debugWindowControlsContentView`.

// The About and Acknowledgments windows (`AboutWindowController`,
// `AcknowledgmentsWindowController`) plus their content views (`AboutPanelView`,
// `AcknowledgmentsView`, `AboutPropertyRow`, `AboutVisualEffectBackground`) now
// live in `CmuxAppKitSupportUI`. `DebugWindowsCoordinator` owns their lifecycle
// (replacing the former `.shared` singletons); the app target injects the
// localized strings and forwards `showAboutPanel()` to
// `debugWindowsCoordinator.showAbout()`.

// MARK: - File Explorer Style Debug
//
// The File Explorer Style debug panel (`FileExplorerStyleDebugView`) now lives in
// `CmuxAppKitSupportUI`. `DebugWindowsCoordinator` mounts the package view; the app
// target snapshots each `FileExplorerStyle` into a `FileExplorerStyleDebugOption`
// (label/description/metrics) and injects the ordered list plus the
// `fileExplorerStyleDidChange` notification post through
// `DebugWindowsCoordinator.fileExplorerStyleDebugContentProvider` (see `AppDelegate`).

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

// The "Startup Appearance Debug" panel (window shell AND SwiftUI content) now
// lives in `CmuxAppKitSupportUI` (`StartupAppearanceDebugWindowController` +
// `StartupAppearanceDebugView`), presented via
// `AppDelegate.shared?.debugWindowsCoordinator.showStartupAppearanceDebug()`. The
// view's app couplings are inverted behind the `StartupAppearanceReloading` seam
// (resolved appearance mode, startup-config cache invalidation, running-app
// reload), conformed app-side by `StartupAppearanceDebugReloader`. Its localized
// labels are resolved app-side (`DebugWindowControlsContentProvider.startupAppearanceDebugStrings`) and
// injected as `StartupAppearanceDebugStrings`, so `String(localized:)` binds to
// the app bundle and keeps its non-English translations. The preview profile and
// synthetic config contents come from `CmuxTerminalCore`. Nothing of this panel
// remains in the app target except the seam conformer and the localized strings.

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
