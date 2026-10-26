import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextInput
import CmuxNextKeepAwake
import CmuxNextLaunch
import CmuxNextPages
import CmuxNextWebUpdates
import CmuxNextPalette
import CmuxNextPhoneAccess
import CmuxNextPopups
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment
    /// The daemon's first connect attempt, begun in `main`.
    private let daemonPrestart: DaemonPrestart?
    /// The launch load-in, region by region; its last region revealing ends the startup phase's
    /// `launching` (made here, the composition root, and passed by init).
    private let launchReveal: LaunchReveal
    /// The startup trace `CMUX_TRACE_STARTUP` asked for (nil: none): launch phases record their slices in it.
    private let startupTrace: StartupTrace?
    /// The app's daemon wire counters, made in `main` (nil in a release build).
    private let wireStats: DaemonWireStats?
    /// The first live terminal frame (or no daemon): reveals the pane region and, with the launch images, starts the control socket.
    private let launchSettle: LaunchSettle
    /// An unavailable daemon's settle: every phase reference and startup ref it ends.
    private let startupReferences: StartupReferences
    /// The launch's order owners, made in `main` (p08-startup-012): every deferred launch task is a post to `order.startup`.
    private let order: LaunchOrder
    /// The agent panes' launch images, one startup ref while any shows (p08-startup-016).
    private let launchImageHold: LaunchImageHold
    /// Cleanup deferred until startup completes (injected; tests pass their own).
    private let launchCleanup: LaunchCleanup
    /// The app's blocking-work lanes and the last quit's pages and composers, read on them since `main`.
    private let launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, wake: AgentPaneRelaunchWake)
    /// Set in applicationDidFinishLaunching; nil before it (no IUO).
    private var services: AppServices?
    /// A second quit signal's exit (`QuitSignal`): the Home cache's last write, bounded, then the end.
    private lazy var forcedQuitExit = ForcedQuitExit(prepare: { [weak self] in
        self?.services?.crashRecovery.applicationWillTerminate()
        AppProcessRoot.shared.hangReports?.applicationWillTerminate()
        self?.services?.home.applicationWillTerminate()
    }, save: { [weak self] in
        await self?.services?.home.flushCacheForQuit()
    })
    private var settings: SettingsController?
    /// The app's one main-thread scheduler (budget, input check, task signposts, starvation guard), handed to control and services.
    private let mainWork: MainWorkScheduler
    /// The main-thread budget's run-loop turn meter; `main` hands it to the application before `run()`.
    var turnMeter: MainTurnMeter { mainWork.budget.turns }
    private let control: AppControl
    /// The one input tap (p04-input.md 3 (A)), made in `main`: pending input, control and services
    /// observe it; `main` installs it on the application before `run()`.
    let inputTap: InputEventTap
    private let mouseSideButtons = MouseSideButtons()
    /// OSC 52 clipboard reads on the local daemon (`TerminalClipboardReadService`).
    var daemonPrompts: DaemonPrompts?
    /// The binding table's Ghostty keybinds, kept current (GHOSTTY-CONFIG).
    private var ghosttyKeybinds: GhosttyKeybindSync?
    /// Watches the exact Ghostty files libghostty loaded and reloads them live.
    private var ghosttyConfigLiveReload: GhosttyConfigLiveReload?
    /// The system's handler for other apps' sign-ins (`WebAuthSessionHandler`, which owns their broker).
    private var webAuthHandler: WebAuthSessionHandler?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    init(environment: AppEnvironment, daemonPrestart: DaemonPrestart?, wireStats: DaemonWireStats?,
         startupTrace: StartupTrace? = nil, order: LaunchOrder, inputTap: InputEventTap,
         launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, wake: AgentPaneRelaunchWake), launchCleanup: LaunchCleanup = LaunchCleanup()) {
        (self.environment, self.launchReads) = (environment, launchReads)
        (self.daemonPrestart, self.startupTrace) = (daemonPrestart, startupTrace)
        self.wireStats = wireStats
        self.launchCleanup = launchCleanup
        self.order = order
        launchImageHold = LaunchImageHold(startup: order.startup)
        // The launch's phase (made in main with the main-thread scheduler) reveals at the first frame.
        let startup = order.mainWork.startup
        let reveal = LaunchReveal(onRevealed: { [startup] in startup.noteFirstFrame() })
        // The restore ref and one ref per visible pane (p08-startup-013): one instance, on the launch's scheduler.
        let paneRefs = VisiblePaneRefs(startup: order.startup, phase: startup)
        (launchReveal, launchSettle) = (reveal, LaunchSettle(reveal: reveal, paneRefs: paneRefs))
        startupReferences = StartupReferences(startup: startup, reveal: reveal, paneRefs: paneRefs)
        (self.mainWork, self.inputTap) = (order.mainWork, inputTap)
        control = AppControl(mainWork: order.mainWork, input: inputTap)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Design mode files a crash left (BrowserDesignModeTempFiles); off the main thread.
        Task.detached(priority: .background) { BrowserDesignModeController.tempFiles.removeAll() }
        // SIGTERM, SIGINT and SIGHUP (dev tooling, `kill`, Ctrl-C) are
        // "Quit, keep sessions" with no alert.
        QuitSignal.install(quit: { [weak self] in
            guard let services = self?.services else { return NSApp.terminate(nil) }
            services.quit.terminateFromSignal()
        }, forceExit: { [weak self] in
            self?.forcedQuitExit.start()
        })
        control.startWatchdog()
        (NSApp as? CmuxApplication)?.inputQueueing = control.watchdog
        DebugTimings.markLaunch("did_finish_launching_start")
        let launchStart = startupTrace?.uptimeNanos
        DebugTimings.install(watchdog: control.watchdog, startupTrace: startupTrace)
        defer {
            DebugTimings.markLaunch("did_finish_launching_end")
            if let launchStart { startupTrace?.task("did_finish_launching", start: launchStart) }
        }
        // No system caret bubble over cmux's own native text fields (before any field edits).
        NativeCaretAccessory.install()
        // Every window, shell or auxiliary, opens by one placement rule.
        WindowPlacement.noActivate = environment.noActivate
        WindowPlacement.testScreen = environment.testWindow?.screen
        // An agent or bench launch must never come back by itself: without this, loginwindow reopens it at
        // the next login (without the agent's environment, so it activates and takes the tag's socket).
        if environment.isolatedLaunch { NSApp.disableRelaunchOnLogin() }
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
        ThemeBridge.start(store: ThemeScope.app.store)
        // The diff page's files live in the app bundle (markdown-viewer/webviews-app).
        PageDescriptor.registerDiffRoot()
        PageDescriptor.registerFilePageRoots()
        PageDescriptor.registerAgentActivityRoot()
        DebugTimings.markLaunch("dfl.theme")
        let services = AppServices(environment: environment, launchReveal: launchReveal, work: launchReads.work, mainWork: mainWork,
                                   launchImages: launchReads.images, relaunchWake: launchReads.wake, wireStats: wireStats, inputTap: inputTap,
                                   launchImageHold: launchImageHold)
        AppProcessRoot.shared.adopt(services)
        self.services = services
        TooltipPresenter.shared.appEvents = services.appEvents  // its inactive-app dismissal shares the app's one observer
        // Frame rate classes (p03-rendering-013): links at their clients' rate, loops at 30 Hz.
        let rateClasses = services.features.isEnabled(.frameRateClasses)
        FrameScheduler.appDisplays.followsClientRates = rateClasses
        DesignSettings.shared.loopsFollowFrameRate = rateClasses
        services.startEnergy()  // before any tab: WebKit, KeepAwake and the video wallpaper start from the inputs
        // VSyncHub (p03-rendering-014): each display's link on that display's vsync thread, one
        // coalesced main post per vsync. Off until the hop measurement is recorded (threading-model.md).
        if services.features.isEnabled(.vsyncHub) { FrameScheduler.appDisplays.hub = VSyncHub() }
        // The settle references, one closure each, before the daemon starts and the windows restore
        // (Chrome's StartupObserver, after_startup_task_utils.cc). A hidden launch (no window on
        // screen) reveals at once.
        let startup = mainWork.startup
        startup.noteLaunch(NSApp.isHidden ? .hidden : .window)
        services.daemon.store.whenFirstSnapshotApplied { startup.markDone(.firstSnapshot) }
        // The restore and visible-page references are the pane refs' (`VisiblePaneRefs.finishRestore`).
        startupReferences.watchUnavailable { [daemon = services.daemon] in daemon.startup.isUnavailable }
        // Hangs, lag spikes and opt-in hang reports (WatchdogReporting); the controller lives with the process.
        AppProcessRoot.shared.adopt(hangReports: WatchdogReporting.install(control.watchdog, services: services))
        services.quit.watchdog = control.watchdog
        DebugTimings.markReveal(services.launchReveal)
        // Debug Settings overrides (DEV and NIGHTLY only) before any window lays out.
        services.debugSettings.start()
        DebugTimings.markLaunch("dfl.services")
        AppActions.bind(services)
        HandlerCoverage.verify(services.registry)
        services.palette.bindRegistryActions()
        let ghosttyKeybinds = GhosttyKeybindSync(router: services.keyRouter, launchImages: launchImageHold)
        self.ghosttyKeybinds = ghosttyKeybinds
        ghosttyKeybinds.start()
        let ghosttyConfigLiveReload = GhosttyConfigLiveReload()
        self.ghosttyConfigLiveReload = ghosttyConfigLiveReload
        ghosttyConfigLiveReload.start()
        // App-scoped Ghostty actions (quit, toggle_visibility, ...) arrive with no surface.
        TerminalHooks(services: services).install()
        // The terminal key path's input-source switch keys, read off main now and on each activation.
        GhosttyRuntime.shared.inputSources.start(runner: services.work)
        DebugTimings.markLaunch("dfl.bind")
        startSettingsAndControl(services: services, launch: settingsRead)
        services.newTabSpares.prewarm() // the first agent page loads while the windows build (cx-z9kz0)
        DebugTimings.markLaunch("dfl.settings")
        NSApp.mainMenu = MainMenu.make(registry: services.registry, blocking: services.blocking)
        DebugTimings.markLaunch("dfl.menu")
        logger.info("unbound catalog actions: \(services.registry.unboundActionIDs().count)")
        WindowActivation.activateApp()
        launchSettle.install(daemon: services.daemon, warmup: services.agentPageWarmup)
        daemonPrompts = DaemonPrompts.start(services)
        services.daemon.start(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                              resolvesShellIntegration: environment.resolvesShellIntegration, prestart: daemonPrestart)
        FeaturePolicyEnforcer(services: services).start()
        services.postCloudStart(on: order.startup)  // no Cloud restore or connect before the first frame (p08-startup 020)
        services.postNonPaintServices(on: order.startup)
        // Before the first window opens (restoreWhenLoaded opens one at once).
        services.windows.onPresent = { [weak services] controller in
            services?.crashRecovery.showRestartNotice(on: controller.window)
        }
        DebugTimings.markLaunch("dfl.daemon_cloud_updater")
        services.windows.onFirstWindow = { [weak services] _ in
            #if DEBUG || CMUX_BENCH_HOOKS
            if let services, services.environment.showcase { _ = DebugShowcase.seed(["focus": .bool(false)], services: services) }
            #endif
            // An App Store request made while no window existed shows in this window (S22).
            if let apps = services?.apps, apps.isStoreWaiting { Task { @MainActor in apps.windowDidShowContent() } }
            // Recovered unsaved changes from a quit, crash or power-off (R96 quit hook).
            if let window = services?.windows.active?.window, let drafts = services?.recoveryDrafts {
                Task { @MainActor in await RecoveryNotice.show(store: drafts, in: window) }
            }
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated { // main-proof: CATransaction.h: the completion block is called on the main thread
                    DebugTimings.markLaunch("first_window_frame_committed")
                    self?.order.startup.firstFrameCommitted()
                }
            }
        }
        // Once startup completes (the visible page loaded, the launch images went), one idle frame each: the palette's
        // panel and command page, so the first open costs what later opens cost (a launcher panel opens in
        // one frame); then the icon picker (its panel, page and symbol catalog), so the first Set Icon opens
        // warm; then the system file picker made ahead, so the first click is not cold.
        LaunchFirstOpenWarmups(paletteSteps: PaletteController.prepareStepNames,
                               preparePalette: { [weak palette = services.palette] in _ = palette?.prepare(step: $0) },
                               prepareIconPicker: { [weak services] in services?.iconPicker.prepare() },
                               warmOpenPanel: { [weak services] in services?.openPanel.warmWhenIdle() }).post(on: order.startup)
        // Temporary download files a crash left in an earlier run (only the
        // recorded ones; the record is read and the files deleted off the
        // main actor). Downloads of this run are never touched.
        launchCleanup.schedule(on: order.startup)
        services.palette.onPresented = { DebugTimings.palettePresented($0) }
        // The key-down that opens the palette (a synthesized one under `debug.key`), for its input stage.
        services.palette.openingEventTimestamp = { [inputDispatch = services.inputDispatch] in
            let event = inputDispatch.event
            return event?.type == .keyDown ? event?.timestamp : nil
        }
        services.iconPicker.onOpened = { DebugTimings.iconPickerOpened($0) }
        let profilesDirectory = BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID)
        services.browserProfiles.load(directory: profilesDirectory, importStore: services.onboarding.importStore)
        DebugTimings.markLaunch("dfl.first_window_hooks")
        services.home.start()
        mouseSideButtons.start { [weak services] in _ = services?.registry.perform($0 == .back ? "focusHistoryBack" : "focusHistoryForward") }
        services.keybindingsFile.start()
        services.bookmarks.start(directory: profilesDirectory, importStore: services.onboarding.importStore)
        services.history.start(supportDirectory: profilesDirectory.deletingLastPathComponent())
        // cmux-page:// first-party pages for Chromium, before any window can start it.
        FirstPartyPageSchemes.install(processGroups: services.features.isEnabled(.pageProcessGroups))
        // The page host already exists (`services.iconPicker` above reads it) but has opened no page;
        // the statics forward to it for page views not yet made through `webUI.open`
        // (p13-webui-006 to 009 move them, 010 deletes the statics).
        PageWebView.openPanel = services.webUI.openPanel
        PageWebView.chromiumHosting = services.webUI.chromium
        DebugTimings.markLaunch("dfl.home_history")
        services.windows.restoreWhenLoaded(paneRefs: launchSettle.paneRefs)
        DebugTimings.markLaunch("dfl.windows")
        // After two quick unexpected ends in a row, Chromium starts only
        // when the user reloads a browser tab.
        services.observeBorders()
        services.observeGlass()
        services.updateFeedObservation = UpdateFeedPosting.follow(services)
        // The runtime pack check wires the engine reason at once; its download waits until asked.
        services.startChromiumRuntime()
        services.postLaterTabWarmups(on: order.startup)
        // Other apps' sign-ins, before any request a launch by one delivers.
        // The engines' incognito profiles and the Chromium engine's sign-in tabs (AppServices).
        let webAuthWindows = WebAuthSessionWindows(host: services, logger: services.daemon.logger,
                                                   profiles: services.browserStores.offTheRecord, signInCallbacks: services.signInCallbacks,
                                                   contextMenus: services.contextMenus)
        let webAuthHandler = WebAuthSessionHandler(broker: WebAuthSessionBroker(opener: webAuthWindows))
        self.webAuthHandler = webAuthHandler
        WebAuthSessionHandler.install(webAuthHandler)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        services.windows.onContentDidAppear = { [weak services] in services?.externalOpen.flush(); services?.pageHostPool.windowDidAppear($0.window) }
        NSApp.servicesProvider = CmuxServicesProvider(open: services.externalOpen)
        // The registered launch work ends the implicit ref. The first window is made in this turn
        // (`restoreWhenLoaded`), so its commit ends the first-frame ref; a launch that shows none
        // completes at the scheduler's failsafe, with reason `failsafe`.
        order.startup.finishRegistration()
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
        // Start the web OTA launch check before any restored or prewarmed page can
        // request its entry document. Otherwise the entry can come from the app
        // bundle while later chunks come from the kept update tree.
        WebUpdates.shared.prepare(launch.snapshot.updates, bundle: .main)
        let registry = services.registry
        let settings = SettingsController(registry: registry, fileURL: launch.fileURL, launch: launch)
        settings.applyManagedFeaturesNow()
        ManagedPolicyBridge(settings: settings, updater: services.updater, auth: services.cloudAuth).start()
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
        settings.start(announcingDiagnostics: true)
        AppProcessRoot.shared.hangReports?.start(settings: settings, asks: services.machineAsks, firstWindow: { [startup = order.startup] in await startup.afterFirstFrame() })
        // An attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) keeps its owner's chat settings.
        let acpmux = QuitAgents.environment(services)
        ChatSettingsPush.start(settings: settings, socketPath: acpmux?.isAttached == true ? nil : acpmux?.socketPath)
        KeepAwakeService.shared.start(settings: settings, store: services.daemon.store)
        services.followEnergySaver(settings)
        services.mobile.follow(settings, launch: services.environment.launch)
        services.chatsFeed?.keepCurrent()
        services.projectsImport.start(feed: services.chatsFeed)
        if let feed = services.chatsFeed { AgentPageChats.wire(services.agentTabs, to: feed, opener: services.chatsOpener) }
        AgentPageChats.wirePager(services.agentTabs, environment: acpmux, opener: services.chatsOpener)
        NewTabClosed.wire(services.agentTabs, services: services)
        NewTabPlacesFeed.wire(services.agentTabs, services: services)
        NewTabWeather.wire(services.agentTabs, services: services)
        // The GitHub connection is deliberately off by default. Changes in
        // Settings apply to the one feed owner and never create a second
        // inbox store.
        Task { [weak services, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await github in ObservationStream({ settings.snapshot.feedGitHub }) {
                services?.configureFeedGitHub(enabled: github.enabled, pollIntervalSeconds: github.pollIntervalSeconds)  // builds no feed
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
        // Agent- and bench-launched builds never take system-wide keys from the person's app.
        if !environment.isolatedLaunch { services.globalHotKeys.start() }
        services.cache.browserTabs.preference.follow(settings)
        BrowserLinkClickPreference.follow(settings, webKit: services.cache.webKit, cef: services.cache.cef)
        WorkspaceAutoNameWiring(services: services).start(settings: settings) // `workspaces.autoName.variant` persist (hq#1957)
        BrowserOmnibarPreference.follow(settings, cache: services.cache)
        services.notifications.follow(settings)
        services.followMacScreenSettings(settings)
        services.startDeviceHub(settings)
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
            await settings.waitForLoad(atLeast: 1); await launchSettle.settled(within: .seconds(4), images: launchImageHold) // control socket: after the first frames (cx-z9kz0; task 019 binds it off main)
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
                control.registerBillingMethods(services)
                control.registerRemoteMethods(services)
                control.registerMobileMethods(services)
                control.registerUpdateMethods(services.updater, services: services)
                control.registerInputMethods(services)
                control.registerSettingsDebugMethods(services)
                control.registerPageDebugMethods(services)
                control.registerRemoteBrowserDebugMethods(services)
                RemoteViewDebugMethods(services: services).register(on: control.service?.router)
                services.registerMacScreenDebug(on: control.service?.router)
                services.registerDeviceHubDebug(on: control.service?.router)
                DebugNowPlaying.register(on: control.service?.router, services: services)
                DebugDownloads.register(on: control.service?.router, services: services)
                DebugCEFDevToolsLayout.register(on: control.service?.router, services: services)
                #if DEBUG
                // The Chromium host app prototype (browserHost.helper; cef-helper-app-DESIGN.md).
                // Socket focus policy: `open` makes the page first responder only with focus: true.
                let chromiumHost = ChromiumHostPrototype(makeConfiguration: { ChromiumHostPrototype.bundledConfiguration() },
                                                         tunables: TunableStore.shared)
                control.service?.router.register([
                    .mainActor("debug.chromium_host") { [weak services] call in
                        let controller = services?.windows.controllers.first
                        let pane = (call.params["pane"]?.stringValue ?? controller?.focus.state.pane).flatMap { controller?.content?.paneController(key: $0) }
                        let fields = chromiumHost.handle(op: call.params["op"]?.stringValue, url: call.params["url"]?.stringValue,
                                                         over: pane?.view.contentHost, focus: call.params["focus"]?.boolValue == true)
                        return .value(JSONValue(foundation: fields) ?? .null)
                    },
                    .async("debug.chromium_host.measure") { call in
                        guard let fields = await chromiumHost.measure(op: call.params["op"]?.stringValue, count: call.params["count"]?.intValue)
                        else { return ["error": "no running Chromium host"] }
                        return .object(fields.mapValues(JSONValue.number))
                    }.withDeadline(.fixed(.seconds(60))),
                ])
                #endif
                DebugBrowserExternal.register(on: control.service?.router, services: services)
                DebugCloudMove.register(on: control.service?.router, services: services)
                DebugTerminalLinks.register(on: control.service?.router, services: services)
                if let router = control.service?.router {
                    // The passkey hand-off: an agent's request waits for the person's banner click.
                    let passkeys = BrowserPasskeyRequests(host: AppBrowserPasskeyHost(services: services))
                    services.notifications.onPasskeyBanner = { id in Task { _ = try? await passkeys.answer(id) } }
                    BrowserPageService(engine: AppBrowserPageEngine(services: services), passkeys: passkeys,
                                       agentMouse: { [weak settings] in
                                           await MainActor.run { settings?.snapshot.browserAgentMouse } ?? AgentMouseSetting().fallback
                                       }).install(on: router)
                    services.apps.attach(router: router)
                }
                logger.info("control socket \(self.control.socketPath ?? "", privacy: .public)")
            } catch {
                logger.error("control socket failed: \(String(describing: error), privacy: .public)")
            }
            // Share This Mac resumes when the person left it on.
            services.macScreenPages.activate()
        }
    }

    /// Every quit (Cmd-Q, the Quit menu, the Dock, `cmux app quit`, power
    /// off) goes through `QuitCoordinator`: it may ask whether to keep the
    /// local terminals (which run in cmux-tui and outlive the app), folds in
    /// the incognito close confirmation, saves windows, and for End stops
    /// the local daemon. `kill` never gets here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        services?.quit.shouldTerminate(sender) ?? .terminateNow
    }

    /// Chromium's `CommandDispatcher` asks NSApp.delegate (in Chrome, its `AppController`) to
    /// validate a `commandDispatch:` item that no Chromium window handles, with no
    /// `respondsToSelector:` check first. Chrome enables only the commands its AppController can
    /// run with no browser window; cmux has no AppController, so those commands are disabled
    /// (enabled, AppKit would send the command where nothing runs it). Any other action is one
    /// this delegate implements, which AppKit enables when it has no validator.
    @objc(validateUserInterfaceItem:) func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action != Selector(("commandDispatch:")) && item.action != Selector(("commandDispatchUsingKeyModifiers:"))
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
        let auth = services.cloudAuth
        let destination = OpenedURLRouting.route(url, isAuthCallback: { auth.isCallback($0) }, open: { services.externalOpen.open($0) })
        guard destination == .auth else { return }
        Task { _ = await auth.handleCallback(url) }  // it starts Cloud first (`CloudAuth.onSignIn`)
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.crashRecovery.applicationWillTerminate()
        AppProcessRoot.shared.hangReports?.applicationWillTerminate()
        ComputerUseHelperDaemon.shared.applicationWillTerminate()
        services?.viewers.diffPages.terminate()
        services?.viewers.markdownPages.terminate()
        services?.viewers.editorPages.terminate()
        // Design mode's Home composer files left by cards still in a draft (BrowserDesignModeTempFiles).
        BrowserDesignModeController.tempFiles.removeAll()
        services?.home.applicationWillTerminate()
        services?.vscodeServeWeb.terminateForAppExit()
        services?.stopCloud()
        services?.ssh.stop()
        services?.serverReach.stop()
        control.stop()
        services?.configActions.stop()
        services?.globalHotKeys.stop()
        settings?.stop()
        services?.mobile.stop()
        services?.iphone.stop()
        services?.daemon.shutdownConnection()
    }

    /// The app stays running with no windows (standard macOS behavior): a window closes when its
    /// last workspace closes, and the daemon keeps every terminal regardless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click with no window open: the last closed window comes back
    /// with its workspaces, else a new window (in background mode a panel or the menu bar item may count as visible).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let services, !hasVisibleWindows || services.background.isBackground else { return true }
        services.windows.reopenOrCreateWindow()
        return false
    }
}
