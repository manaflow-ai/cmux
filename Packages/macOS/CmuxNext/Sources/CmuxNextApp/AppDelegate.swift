import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextKeepAwake
import CmuxNextPages
import CmuxNextPalette
import CmuxNextPhoneAccess
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
    /// Set in applicationDidFinishLaunching; nil before it (no IUO).
    private var services: AppServices?
    private var settings: SettingsController?
    private let control = AppControl()
    private var cloudContext: Task<Void, Never>?
    /// OSC 52 clipboard reads on the local daemon (`TerminalClipboardReadService`).
    var daemonPrompts: DaemonPrompts?
    /// The binding table's Ghostty keybinds, kept current (GHOSTTY-CONFIG).
    private var ghosttyKeybinds: GhosttyKeybindSync?
    /// Watches the exact Ghostty files libghostty loaded and reloads them live.
    private var ghosttyConfigLiveReload: GhosttyConfigLiveReload?
    /// The system's handler for other apps' sign-ins (`WebAuthSessionHandler`, which owns their broker).
    private var webAuthHandler: WebAuthSessionHandler?
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
        // An agent launch must never come back by itself: without this, loginwindow reopens it at the
        // next login (without the agent's environment, so it activates and takes the tag's socket).
        if environment.noActivate { NSApp.disableRelaunchOnLogin() }
        // A `cmux` shim outside this app runs the CLI of the app opened last
        // (plans/cmux-next/version-skew.md); an isolated launch never claims it.
        if LastAppCLIPointer.shouldPublish(environment: ProcessInfo.processInfo.environment),
           let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux").path {
            Task.detached(priority: .utility) { LastAppCLIPointer().publish(cliPath: cli) }
        }
        // cmux.json's appearance goes on the Ghostty overrides before the
        // runtime's first config load, so the first frame needs no reload.
        let settingsRead = SettingsController.readAtLaunch(fileURL: settingsFileURL())
        TerminalThemeSetting.prime(settingsRead.snapshot)
        DebugTimings.markLaunch("dfl.settings_read")
        // Chrome colors derive from the Ghostty theme; load it before any window.
        ThemeBridge.start()
        // The diff page's files live in the app bundle (markdown-viewer/webviews-app).
        PageDescriptor.registerDiffRoot()
        PageDescriptor.registerFilePageRoots()
        DebugTimings.markLaunch("dfl.theme")
        let services = AppServices(environment: environment)
        AppProcessRoot.shared.adopt(services)
        self.services = services
        // A main-thread hang still running after 2 s goes to crash reporting with its stack.
        let reporter = services.crashReporting.reporter
        control.watchdog.onHang = { hang in reporter.reportHang(duration: hang.duration, addresses: hang.addresses) }
        // Shorter lag spikes (250 ms and up, rate-limited) go there too, once they end.
        let lagSpikes = LagSpikeReporter(reporter: reporter)
        lagSpikes.setContextProvider {
            MainActor.assumeIsolated {
                let windows = NSApp.windows
                return ["windows": String(windows.count), "visible_windows": String(windows.filter(\.isVisible).count),
                        "app_active": NSApp.isActive ? "yes" : "no"]
            }
        }
        control.watchdog.onStall = { record in
            lagSpikes.noteStall(duration: record.duration, cpu: record.cpu, addresses: record.addresses)
        }
        services.quit.watchdog = control.watchdog
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
        let ghosttyConfigLiveReload = GhosttyConfigLiveReload()
        self.ghosttyConfigLiveReload = ghosttyConfigLiveReload
        ghosttyConfigLiveReload.start()
        // App-scoped Ghostty actions (quit, toggle_visibility, ...) arrive with no surface.
        TerminalHooks(services: services).install()
        DebugTimings.markLaunch("dfl.bind")
        startSettingsAndControl(services: services, launch: settingsRead)
        services.newTabSpares.prewarm() // the first agent page loads while the windows build (cx-z9kz0)
        DebugTimings.markLaunch("dfl.settings")
        NSApp.mainMenu = MainMenu.make(registry: services.registry)
        DebugTimings.markLaunch("dfl.menu")
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        WindowActivation.activateApp()
        launchSettle.install(daemon: services.daemon)
        daemonPrompts = DaemonPrompts.start(services)
        services.daemon.start(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                              resolvesShellIntegration: environment.resolvesShellIntegration, prestart: daemonPrestart)
        FeaturePolicyEnforcer(services: services).start()
        cloudContext = services.startCloud()
        FreeTierAttestStarter(build: environment.build, bundle: .main, apiBaseURL: services.feed.apiBaseURL, settings: services.settings, signedIn: { [weak services] in services.map { $0.cloud.isSignedIn || $0.cloud.auth.isRestoring } ?? true }).start()
        services.ssh.start()
        services.serverReach.start()
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
            // An App Store request made while no window existed shows in this window (S22).
            if let apps = services?.apps, apps.isStoreWaiting { Task { @MainActor in apps.windowDidShowContent() } }
            // Recovered unsaved changes from a quit, crash or power-off (R96 quit hook).
            if let window = services?.windows.active?.window { Task { @MainActor in await RecoveryNotice.show(in: window) } }
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated { DebugTimings.markLaunch("first_window_frame_committed") } // main-proof: CATransaction.h: the completion block is called on the main thread
            }
        }
        // Once the first terminal frame is drawn, the palette panel is made
        // at the next idle moment, so the first open costs what later opens
        // cost (a launcher panel opens in one frame), without
        // delaying that frame.
        // Then the icon picker (its panel, page and symbol catalog), so the first Set Icon opens warm.
        launchSettle.whenSettled { [palette = services.palette, weak services] in
            Self.preparePalette(palette, step: 0) { IdleOnce.schedule { services?.iconPicker.prepare() } }
        }
        // Temporary download files a crash left in an earlier run (only the
        // recorded ones; the record is read and the files deleted off the
        // main actor). Downloads of this run are never touched.
        launchCleanup.schedule(on: launchSettle)
        services.palette.onPresented = { DebugTimings.palettePresented($0) }
        services.iconPicker.onOpened = { DebugTimings.iconPickerOpened($0) }
        services.browserProfiles.load(directory: BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID),
                                      importStore: services.onboarding.importStore)
        services.home.start()
        services.keybindingsFile.start()
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
        services.pageHostPool.start(
            isMainWindow: { [weak services] window in
                services?.windows.controllers.contains { $0.window === window } == true
            },
            fallback: { [weak services] window in
                services?.windows.controllers.compactMap(\.window).first { $0 !== window && $0.isVisible }
            })
        services.pageHostPool.noteLikely()
        AgentTabImport.start(services)
        // Other apps' sign-ins, before any request a launch by one delivers.
        let webAuthHandler = WebAuthSessionHandler(broker: WebAuthSessionBroker(opener: WebAuthSessionWindows(services: services)))
        self.webAuthHandler = webAuthHandler
        WebAuthSessionHandler.install(webAuthHandler)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        services.windows.onContentDidAppear = { [weak services] _ in services?.externalOpen.flush() }
        NSApp.servicesProvider = CmuxServicesProvider(open: services.externalOpen)
    }

    /// One palette warm-up step per idle moment (`PaletteController.prepare`), then `done`.
    private static func preparePalette(_ palette: PaletteController?, step: Int, done: @escaping @MainActor () -> Void) {
        IdleOnce.schedule {
            guard let palette, palette.prepare(step: step) else { return done() }
            preparePalette(palette, step: step + 1, done: done)
        }
    }

    /// cmux.json, created on first launch.
    private func settingsFileURL() -> URL {
        do {
            return try CmuxConfigFile.prepareDefaultURL()
        } catch {
            logger.error("cmux-next config bootstrap failed: \(String(describing: error), privacy: .public)")
            return CmuxConfigFile.defaultURL()
        }
    }

    /// cmux-next.json settings and the tagged control socket (`action.list/describe/run`) over the same registry.
    private func startSettingsAndControl(services: AppServices, launch: SettingsController.LaunchRead) {
        let registry = services.registry
        let settings = SettingsController(registry: registry, fileURL: launch.fileURL, launch: launch)
        settings.applyManagedFeaturesNow()
        ManagedPolicyBridge(settings: settings, updater: services.updater, auth: services.cloud.auth).start()
        self.settings = settings
        services.settings = settings
        UserOnlySettingConfirmation.install(settings, services: services)
        // Every palette-exposed schema setting in the palette (R93).
        services.palette.sources.settings = SettingsPaletteSource(settings: settings, themes: services.themes.catalog) { [weak services] in
            services?.windows.active.map { SettingsPaletteSource.themeColors($0.themeScope.tokens) } ?? []
        }
        services.history.startDaemonSync(settings: settings)
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
        ChatSettingsPush.start(settings: settings, environment: QuitAgents.environment(services))
        KeepAwakeService.shared.start(settings: settings, store: services.daemon.store)
        services.mobile.follow(settings, launch: services.environment.launch)
        services.chatsFeed?.keepCurrent()
        services.projectsImport.start(feed: services.chatsFeed)
        if let feed = services.chatsFeed { AgentPageChats.wire(services.agentTabs, to: feed, opener: services.chatsOpener) }
        AgentPageChats.wirePager(services.agentTabs, environment: QuitAgents.environment(services), opener: services.chatsOpener)
        NewTabClosed.wire(services.agentTabs, services: services)
        NewTabPlacesFeed.wire(services.agentTabs, services: services)
        // The GitHub connection is deliberately off by default. Changes in
        // Settings apply to the one feed owner and never create a second
        // inbox store.
        Task { [weak services, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await github in ObservationStream({ settings.snapshot.feedGitHub }) {
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
        WorkspaceAutoNameWiring(services: services).start(settings: settings) // `workspaces.autoName.variant` persist (hq#1957)
        BrowserOmnibarPreference.follow(settings, cache: services.cache)
        services.notifications.follow(settings)
        services.updater.follow(settings)
        ComputerUseHelperDaemon.shared.follow(settings, disabledByPolicy: { [weak services] in
            services?.registry.disabledFeatures.contains(.computerUse) ?? true
        })
        services.startHibernation(settings: settings)
        services.terminalTheme.follow(settings)
        services.themes.start()
        services.themes.followChromeTheme(settings)
        services.remoteLocalhost.follow(settings)
        services.bookmarks.follow(settings)
        services.apps.start()
        Task {
            await settings.waitForLoad(atLeast: 1); await launchSettle.settled(within: .seconds(4)) // control socket: after the first frames (cx-z9kz0)
            // `app.quitBehavior: "end"` (first release) is now "end-keep-layout".
            _ = try? await settings.migrateLegacyQuitBehavior()
            _ = try? await settings.migrateLegacyWorkspaceRowKeys() // `sidebar.showWorkspaceDirectory` / `showCounts` move to `sidebar.workspaceRow.*`
            _ = try? await settings.migrateLegacyPaneToolbarButtons() // `tabs.hiddenButtons` becomes `tabs.toolbarButtons`
            // Classic cmux keys next reads under another name (`ClassicSettingRename`).
            _ = try? await settings.migrateClassicSettings()
            // Shortcuts and settings classic cmux's Settings kept in its preferences (`ClassicShortcutImport`, `ClassicPreferenceImport`).
            _ = try? await settings.importClassicShortcuts(marker: .standard)
            _ = try? await settings.importClassicPreferences(marker: .standard)
            do {
                try control.start(registry: registry, settings: settings, launch: environment.launch, services: services)
                control.registerCloudMethods(services)
                control.registerAccountsMethods(services)
                control.registerRemoteMethods(services)
                control.registerMobileMethods(services)
                control.registerUpdateMethods(services.updater, services: services)
                control.registerInputMethods(services)
                control.registerSettingsDebugMethods(services)
                control.registerPageDebugMethods(services)
                control.registerRemoteBrowserDebugMethods(services)
                RemoteViewDebugMethods(services: services).register(on: control.service?.router)
                DebugNowPlaying.register(on: control.service?.router, services: services)
                DebugDownloads.register(on: control.service?.router, services: services)
                DebugCEFDevToolsLayout.register(on: control.service?.router, services: services)
                DebugBrowserExternal.register(on: control.service?.router, services: services)
                DebugCloudMove.register(on: control.service?.router, services: services)
                DebugTerminalLinks.register(on: control.service?.router, services: services)
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
    @objc(handleURLEvent:reply:) private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        routeOpenedURL(url)
    }

    /// Files opened with cmux (every document type in Info.plist) and URLs delivered
    /// without an Apple event, routed like the Apple event's.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { routeOpenedURL(url) }
    }

    /// Handoff of a web page (cmux as the default browser, Info.plist
    /// `NSUserActivityTypes`): it opens as a browser tab, like a link.
    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        userActivityType == NSUserActivityTypeBrowsingWeb
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        services?.externalOpen.continueActivity(type: userActivity.activityType, webpageURL: userActivity.webpageURL) ?? false
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
        ComputerUseHelperDaemon.shared.applicationWillTerminate()
        services?.viewers.diffPages.terminate()
        services?.viewers.markdownPages.terminate()
        services?.viewers.editorPages.terminate()
        services?.home.applicationWillTerminate()
        cloudContext?.cancel()
        services?.cloud.stop()
        for session in services?.machines.cloud ?? [] { session.disconnect() }
        services?.ssh.stop()
        services?.serverReach.stop()
        control.stop()
        services?.configActions.stop()
        services?.globalHotKeys.stop()
        settings?.stop()
        services?.mobile.stop()
        services?.daemon.shutdownConnection()
    }

    /// The app stays running with no windows (standard macOS behavior): a window closes when its
    /// last workspace closes, and the daemon keeps every terminal regardless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click with no window open: the last closed window comes back with its workspaces, else a new window with a new workspace.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let windows = services?.windows else { return true }
        windows.reopenOrCreateWindow()
        return false
    }
}
