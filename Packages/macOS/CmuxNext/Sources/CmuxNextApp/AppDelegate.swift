import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTerminal
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment
    /// The daemon's first connect attempt, begun in `main`.
    private let daemonPrestart: DaemonPrestart?
    /// The first live terminal frame (or no daemon): deferrable warm-up waits for it.
    private let launchSettle = LaunchSettle()
    /// Cleanup deferred until the launch settles (injected; tests pass their own).
    private let launchCleanup: LaunchCleanup
    private var services: AppServices!
    private var settings: SettingsController?
    private let control = AppControl()
    private var cloudContext: Task<Void, Never>?
    /// OSC 52 clipboard reads on the local daemon (`TerminalClipboardReadService`).
    private var clipboardReads: TerminalClipboardReadService?
    /// The binding table's Ghostty keybinds, kept current (GHOSTTY-CONFIG).
    private var ghosttyKeybinds: GhosttyKeybindSync?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    init(environment: AppEnvironment, daemonPrestart: DaemonPrestart?, launchCleanup: LaunchCleanup = LaunchCleanup()) {
        self.environment = environment
        self.daemonPrestart = daemonPrestart
        self.launchCleanup = launchCleanup
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM, SIGINT and SIGHUP (dev tooling, `kill`, Ctrl-C) are
        // "Quit, keep sessions" with no alert.
        QuitSignal.install(quit: { [weak self] in
            guard let services = self?.services else { return NSApp.terminate(nil) }
            services.quit.terminateFromSignal()
        }, forceExit: { [weak self] in
            self?.services?.crashRecovery.applicationWillTerminate()
            self?.services?.home.applicationWillTerminate()
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
        // The diff page's files live in the app bundle (markdown-viewer/webviews-app).
        PageDescriptor.registerDiffRoot()
        PageDescriptor.registerFilePageRoots()
        DebugTimings.markLaunch("dfl.theme")
        let services = AppServices(environment: environment)
        self.services = services
        DebugTimings.markReveal(services.launchReveal)
        // Debug Settings overrides (DEV and NIGHTLY only) before any window lays out.
        services.debugSettings.start()
        DebugTimings.markLaunch("dfl.services")
        AppActions.bind(services)
        HandlerCoverage.verify(services.registry)
        services.palette.bindRegistryActions()
        let ghosttyKeybinds = GhosttyKeybindSync(router: services.keyRouter)
        self.ghosttyKeybinds = ghosttyKeybinds
        ghosttyKeybinds.start()
        // App-scoped Ghostty actions (quit, toggle_visibility, ...) arrive with no surface.
        TerminalHooks(services: services).install()
        DebugTimings.markLaunch("dfl.bind")
        startSettingsAndControl(registry: services.registry)
        DebugTimings.markLaunch("dfl.settings")
        NSApp.mainMenu = MainMenu.make(registry: services.registry)
        DebugTimings.markLaunch("dfl.menu")
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        WindowActivation.activateApp()
        launchSettle.install(daemon: services.daemon)
        let clipboardReads = TerminalClipboardReadService(services: services)
        self.clipboardReads = clipboardReads
        clipboardReads.start()
        services.daemon.start(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                              resolvesShellIntegration: environment.resolvesShellIntegration, prestart: daemonPrestart)
        FeaturePolicyEnforcer(services: services).start()
        cloudContext = services.startCloud()
        services.ssh.start()
        services.updater.start()
        // Before the first window opens (restoreWhenLoaded opens one at once).
        services.windows.onPresent = { [weak services] controller in
            services?.crashRecovery.showRestartNotice(on: controller.window)
        }
        DebugTimings.markLaunch("dfl.daemon_cloud_updater")
        services.windows.onFirstWindow = { [weak services] _ in
            #if DEBUG
            if let services, services.environment.showcase { _ = DebugShowcase.seed(["focus": .bool(false)], services: services) }
            #endif
            // Recovered unsaved changes from a quit, crash or power-off (R96 quit hook).
            if let window = services?.windows.active?.window { Task { @MainActor in await RecoveryNotice.show(in: window) } }
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated { DebugTimings.markLaunch("first_window_frame_committed") }
            }
        }
        // Once the first terminal frame is drawn, the palette panel is made
        // at the next idle moment, so the first open costs what later opens
        // cost (a launcher panel opens in one frame), without
        // delaying that frame.
        launchSettle.whenSettled { [palette = services.palette] in Self.preparePalette(palette, step: 0) }
        // Temporary download files a crash left in an earlier run (only the
        // recorded ones; the record is read and the files deleted off the
        // main actor). Downloads of this run are never touched.
        launchCleanup.schedule(on: launchSettle)
        services.palette.onPresented = { DebugTimings.palettePresented($0) }
        services.browserProfiles.load(directory: BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID),
                                      importStore: services.onboarding.importStore)
        services.home.start()
        services.bookmarks.start(directory: BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID),
                                 importStore: services.onboarding.importStore)
        services.history.start(supportDirectory: BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID)
            .deletingLastPathComponent())
        // cmux-page:// first-party pages for Chromium, before any window can start it.
        FirstPartyPageSchemes.install()
        services.windows.restoreWhenLoaded()
        DebugTimings.markLaunch("dfl.windows")
        // After two quick unexpected ends in a row, Chromium starts only
        // when the user reloads a browser tab.
        services.observeBorders()
        if !services.crashRecovery.recovery.skipsBrowserPages { services.startChromiumWarmup() }
        services.newTabSpares.start()
        AgentTabImport.start(services)
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

    /// cmux-next.json settings (density, shortcut overrides) and the tagged
    /// control socket (`action.list/describe/run`) over the same registry.
    private func startSettingsAndControl(registry: ActionRegistry) {
        let fileURL: URL
        do {
            fileURL = try CmuxConfigFile.prepareDefaultURL()
        } catch {
            logger.error("cmux-next config bootstrap failed: \(String(describing: error), privacy: .public)")
            fileURL = CmuxConfigFile.defaultURL()
        }
        let settings = SettingsController(registry: registry, fileURL: fileURL)
        settings.applyManagedFeaturesNow()
        ManagedPolicyBridge(settings: settings, updater: services.updater, auth: services.cloud.auth).start()
        self.settings = settings
        services.settings = settings
        UserOnlySettingConfirmation.install(settings, services: services)
        // Every palette-exposed schema setting in the palette (R93).
        services.palette.sources.settings = SettingsPaletteSource(settings: settings, themes: services.themes.catalog) { [weak services] in
            services?.windows.active.map { SettingsPaletteSource.themeColors($0.themeScope.tokens) } ?? []
        }
        services.history.commands.start(settings: settings)
        services.locationTrail.watchScope(settings: settings)
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
        // The GitHub connection is deliberately off by default. Changes in
        // Settings apply to the one feed owner and never create a second
        // inbox store.
        Task { [weak services, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await github in Observations({ settings.snapshot.feedGitHub }) {
                services?.feed.configureGitHub(enabled: github.enabled, pollIntervalSeconds: github.pollIntervalSeconds)
            }
        }
        // macOS posts no notification when an MDM profile changes; activation
        // is the event-driven backstop next to the managed-file watchers.
        Task { [weak settings] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                settings?.managedPreferencesMayHaveChanged()
            }
        }
        services.configActions.start(settings: settings)
        // Agent-launched builds never take system-wide keys from the person's app.
        if !environment.noActivate { services.globalHotKeys.start() }
        services.cache.browserTabs.preference.follow(settings)
        BrowserLinkClickPreference.follow(settings, webKit: services.cache.webKit, cef: services.cache.cef)
        BrowserOmnibarPreference.follow(settings, cache: services.cache)
        services.notifications.follow(settings)
        services.updater.follow(settings)
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
                control.registerUpdateMethods(services.updater, services: services)
                control.registerInputMethods(services)
                control.registerSettingsDebugMethods(services)
                control.registerPageDebugMethods()
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
    /// tabs; links in this build's scheme (`cmux://tab/…`) run `link.open`;
    /// `<scheme>://auth-callback` from the browser fallback of sign-in goes
    /// to Cloud auth.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        routeOpenedURL(url)
    }

    /// Files opened with cmux (scripts, folders, HTML) and URLs delivered
    /// without an Apple event, routed like the Apple event's.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { routeOpenedURL(url) }
    }

    /// One route for every URL macOS hands cmux (`OpenedURLRouting`): the
    /// sign-in callback to Cloud auth first, in every form auth accepts,
    /// then `ExternalOpenRouter`.
    private func routeOpenedURL(_ url: URL) {
        guard let services else { return }
        let auth = services.cloud.auth
        let destination = OpenedURLRouting.route(url, isAuthCallback: { auth.isCallback($0) }, open: { services.externalOpen.open($0) })
        guard destination == .auth else { return }
        Task { _ = await auth.handleCallback(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.crashRecovery.applicationWillTerminate()
        services?.viewers.diffPages.terminate()
        services?.viewers.markdownPages.terminate()
        services?.viewers.editorPages.terminate()
        services?.home.applicationWillTerminate()
        cloudContext?.cancel()
        services?.cloud.stop()
        for session in services?.machines.cloud ?? [] { session.disconnect() }
        services?.ssh.stop()
        control.stop()
        services?.configActions.stop()
        services?.globalHotKeys.stop()
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
