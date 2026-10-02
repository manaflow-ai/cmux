import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPalette
import CmuxNextSettings
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment
    /// The daemon's first connect attempt, begun in `main`.
    private let daemonPrestart: DaemonPrestart?
    /// The first live terminal frame (or no daemon): deferrable warm-up waits for it.
    private let launchSettle = LaunchSettle()
    private var services: AppServices!
    private var settings: SettingsController?
    private let control = AppControl()
    private var cloudContext: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    init(environment: AppEnvironment, daemonPrestart: DaemonPrestart?) {
        self.environment = environment
        self.daemonPrestart = daemonPrestart
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM (dev tooling, `kill`) is "Quit, keep sessions" with no alert.
        QuitSignal.install(quit: { [weak self] in
            guard let services = self?.services else { return NSApp.terminate(nil) }
            services.quit.terminateFromSignal()
        }, forceExit: { [weak self] in
            self?.services?.crashRecovery.applicationWillTerminate()
            exit(0)
        })
        control.startWatchdog()
        DebugTimings.markLaunch("did_finish_launching_start")
        DebugTimings.install()
        defer { DebugTimings.markLaunch("did_finish_launching_end") }
        // Every window, shell or auxiliary, opens by one placement rule.
        WindowPlacement.noActivate = environment.noActivate
        WindowPlacement.testScreen = environment.testWindow?.screen
        // An agent launch must never come back by itself: without this,
        // loginwindow reopens it at the next login (without the agent's
        // environment, so it activates and takes the tag's socket).
        if environment.noActivate { NSApp.disableRelaunchOnLogin() }
        // Chrome colors derive from the Ghostty theme; load it before any window.
        ThemeBridge.start()
        DebugTimings.markLaunch("dfl.theme")
        let services = AppServices(environment: environment)
        self.services = services
        // Debug Settings overrides (DEV and NIGHTLY only) before any window lays out.
        services.debugSettings.start()
        DebugTimings.markLaunch("dfl.services")
        AppActions.bind(services)
        HandlerCoverage.verify(services.registry)
        services.palette.bindRegistryActions()
        DebugTimings.markLaunch("dfl.bind")
        startSettingsAndControl(registry: services.registry)
        DebugTimings.markLaunch("dfl.settings")
        NSApp.mainMenu = MainMenu.make(registry: services.registry)
        DebugTimings.markLaunch("dfl.menu")
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        WindowActivation.activateApp()
        launchSettle.install(daemon: services.daemon)
        services.daemon.start(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(), prestart: daemonPrestart)
        cloudContext = services.startCloud()
        services.ssh.start()
        services.updater.start()
        // Before the first window opens (restoreWhenLoaded opens one at once).
        services.windows.onPresent = { [weak services] controller in
            services?.crashRecovery.showRestartNotice(on: controller.window)
        }
        DebugTimings.markLaunch("dfl.daemon_cloud_updater")
        services.windows.onFirstWindow = { _ in
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated { DebugTimings.markLaunch("first_window_frame_committed") }
            }
        }
        // Once the first terminal frame is drawn, the palette panel is made
        // at the next idle moment, so the first open costs what later opens
        // cost (Spotlight and Chrome's omnibox open in one frame), without
        // delaying that frame.
        launchSettle.whenSettled { [palette = services.palette] in Self.preparePalette(palette, step: 0) }
        services.palette.onPresented = { DebugTimings.palettePresented($0) }
        services.browserProfiles.load(directory: BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID),
                                      importStore: services.onboarding.importStore)
        services.bookmarks.start(directory: BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID),
                                 importStore: services.onboarding.importStore)
        services.history.start(supportDirectory: BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID)
            .deletingLastPathComponent())
        services.windows.restoreWhenLoaded()
        DebugTimings.markLaunch("dfl.windows")
        // After two quick unexpected ends in a row, Chromium starts only
        // when the user reloads a browser tab.
        services.observeBorders()
        if !services.crashRecovery.recovery.skipsBrowserPages { services.startChromiumWarmup() }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        services.windows.onContentDidAppear = { [weak services] _ in services?.externalOpen.flush() }
        NSApp.servicesProvider = CmuxServicesProvider(open: services.externalOpen)
        services.onboarding.showIfNeeded()
    }

    /// One palette warm-up step per idle moment (`PaletteController.prepare`).
    private static func preparePalette(_ palette: PaletteController?, step: Int) {
        IdleOnce.schedule {
            guard let palette, palette.prepare(step: step) else { return }
            preparePalette(palette, step: step + 1)
        }
    }

    /// cmux.json settings (density, shortcut overrides) and the tagged
    /// control socket (`action.list/describe/run`) over the same registry.
    private func startSettingsAndControl(registry: ActionRegistry) {
        let settings = SettingsController(registry: registry)
        self.settings = settings
        services.settings = settings
        services.history.commands.start(settings: settings)
        let shortcutEditor = PaletteShortcutEditor(services: services, settings: settings)
        services.paletteShortcutEditor = shortcutEditor
        services.palette.shortcutRecorder.editor = shortcutEditor
        // Managed-settings status for MDM tooling (osquery, Fleet, Jamf), plans/cmux-next/enterprise.md.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        settings.writeManagedStatus(
            to: ManagedStatusReport.defaultURL(bundleID: bundleID),
            context: ManagedStatusReport.Context(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                bundleID: bundleID
            )
        )
        settings.start()
        // macOS posts no notification when an MDM profile changes; activation
        // is the event-driven backstop next to the managed-file watchers.
        Task { [weak settings] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                settings?.managedPreferencesMayHaveChanged()
            }
        }
        services.tabBarButtons.start(settings: settings)
        services.cache.browserTabs.preference.follow(settings)
        services.notifications.follow(settings)
        services.startHibernation(settings: settings)
        services.terminalTheme.follow(settings)
        services.themes.start()
        services.remoteLocalhost.follow(settings)
        services.bookmarks.follow(settings)
        services.apps.start()
        Task {
            await settings.waitForLoad(atLeast: 1)
            // `app.quitBehavior: "end"` (first release) is now "end-keep-layout".
            _ = try? await settings.migrateLegacyQuitBehavior()
            do {
                try control.start(registry: registry, settings: settings, launch: environment.launch, services: services)
                control.registerCloudMethods(services)
                control.registerAccountsMethods(services)
                control.registerRemoteMethods(services)
                control.registerMobileMethods(services)
                control.registerUpdateMethods(services.updater)
                control.registerInputMethods(services)
                control.registerSettingsDebugMethods(services)
                if let router = control.service?.router {
                    BrowserPageService(engine: AppBrowserPageEngine(services: services)).install(on: router)
                    services.apps.attach(router: router)
                }
                logger.info("control socket \(self.control.socketPath ?? "", privacy: .public)")
            } catch {
                logger.error("control socket failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Every quit (Cmd-Q, the Quit menu, the Dock, `cmux app quit`, power
    /// off) goes through `QuitCoordinator`: it may ask whether to keep the
    /// local terminals (which run in cmux-tui and outlive the app), folds in
    /// the incognito close confirmation, saves windows, and for End stops
    /// the local daemon. `kill` never gets here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services else { return .terminateNow }
        return services.quit.shouldTerminate(sender)
    }

    /// Web, `ssh:` and `x-man-page:` links (cmux as their handler) open as
    /// tabs; `<scheme>://auth-callback` from the browser fallback of
    /// sign-in goes to Cloud auth.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        if services?.externalOpen.open(url) == true { return }
        let cloud = services?.cloud
        Task { _ = await cloud?.auth.handleCallback(url) }
    }

    /// Files opened with cmux (scripts, folders, HTML) and URLs delivered
    /// without an Apple event.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { services?.externalOpen.open(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.crashRecovery.applicationWillTerminate()
        cloudContext?.cancel()
        services?.cloud.stop()
        for session in services?.machines.cloud ?? [] { session.disconnect() }
        services?.ssh.stop()
        control.stop()
        services?.tabBarButtons.stop()
        settings?.stop()
        services?.mobile.stop()
        services?.daemon.shutdownConnection()
    }

    /// The app stays running with no windows (standard macOS behavior): a
    /// window closes when its last workspace closes, and the daemon keeps
    /// every terminal regardless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click with no window open: the last closed window comes back
    /// with its workspaces, else a new window with a new workspace.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let windows = services?.windows else { return true }
        windows.reopenOrCreateWindow()
        return false
    }
}
