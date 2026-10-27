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
import CmuxNextLaunch
import CmuxNextPages
import CmuxNextWebUpdates
import CmuxNextPalette
import CmuxNextPhoneAccess
import CmuxNextPopups
import CmuxNextSettings
import CmuxNextSignposts
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
    /// The app's daemon wire counters, made in `main` (nil in a release build without field data opt-in).
    private let wireStats: DaemonWireStats?
    /// The launch's feature list from the composition root (``AppServices/launchFeatures(_:)``).
    private let features: FeatureList?
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
    /// cmux-next.json and the managed layers, read on the files lane since `main` (p08-startup 025).
    private let settingsRead: SettingsController.PendingLaunchRead
    /// Set in applicationDidFinishLaunching; nil before it (no IUO).
    private var services: AppServices?
    /// URLs and Handoff activities macOS handed over before the services existed (the settings read still in flight).
    private let launchOpens = LaunchOpenQueue()
    /// A second quit signal's exit (`QuitSignal`): the Home cache's last write, bounded, then the end.
    private lazy var forcedQuitExit = ForcedQuitExit(prepare: { [weak self] in
        self?.services?.crashRecovery.applicationWillTerminate()
        AppProcessRoot.shared.hangReports?.applicationWillTerminate()
        self?.services?.home.applicationWillTerminate()
    }, save: { [weak self] in
        await self?.services?.home.flushCacheForQuit()
    })
    private var settings: SettingsController?
    /// The control socket bound on a lane after the settings launch read (feature `controlSocketEarlyBind`, AppControl.beginBind).
    private var controlSocket: ControlSocketBind?
    /// The app's one main-thread scheduler (budget, input check, task signposts, starvation guard), handed to control and services.
    private let mainWork: MainWorkScheduler
    /// The main-thread budget's run-loop turn meter; `main` hands it to the application before `run()`.
    var turnMeter: MainTurnMeter { mainWork.budget.turns }
    private let control: AppControl
    /// The one input tap (p04-input.md 3 (A)), made in `main`: pending input, control and services
    /// observe it; `main` installs it on the application before `run()`.
    let inputTap: InputEventTap
    private let mouseSideButtons: MouseSideButtons
    /// OSC 52 clipboard reads on the local daemon (`TerminalClipboardReadService`).
    var daemonPrompts: DaemonPrompts?
    /// The binding table's Ghostty keybinds, kept current (GHOSTTY-CONFIG).
    private var ghosttyKeybinds: GhosttyKeybindSync?
    /// Watches the exact Ghostty files libghostty loaded and reloads them live.
    private var ghosttyConfigLiveReload: GhosttyConfigLiveReload?
    /// The system's handler for other apps' sign-ins (`WebAuthSessionHandler`, which owns their broker).
    private var webAuthHandler: WebAuthSessionHandler?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    init(environment: AppEnvironment, daemonPrestart: DaemonPrestart?, wireStats: DaemonWireStats?, features: FeatureList? = nil,
         startupTrace: StartupTrace? = nil, order: LaunchOrder, inputTap: InputEventTap, settingsRead: SettingsController.PendingLaunchRead,
         launchReads: (work: BackgroundWork, images: AgentPaneLaunchImages, wake: AgentPaneRelaunchWake), launchCleanup: LaunchCleanup = LaunchCleanup()) {
        (self.environment, self.launchReads, self.settingsRead) = (environment, launchReads, settingsRead)
        (self.daemonPrestart, self.startupTrace) = (daemonPrestart, startupTrace)
        (self.wireStats, self.features) = (wireStats, features)
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
        let control = AppControl(mainWork: order.mainWork, input: inputTap)
        #if CMUX_PGO_PROFILE
        control.profileFlush = order.profileFlush
        #endif
        self.control = control
        mouseSideButtons = MouseSideButtons(input: inputTap)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Design mode files an earlier launch's crash left (BrowserDesignModeTempFiles): nobody waits, so behind the
        // best-effort fence. This launch's cards are in their own folder, which the cleanup keeps.
        order.startup.post(.afterStartup, "BrowserDesignMode.tempFiles", on: .lane(.files, .bestEffort)) { BrowserDesignModeController.tempFiles.removeEarlierRuns() }
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
            order.startup.post(.afterStartup, "LastAppCLIPointer.publish", on: .lane(.files, .bestEffort)) { _ = LastAppCLIPointer().publish(cliPath: cli) }
        }
        // The rest runs with main()'s settings read, now or when it lands (the startup's main hop, unbudgeted):
        // no wait, no frame in the defaults (p08-startup 025). The launch marks end where the launch work ends.
        settingsRead.whenRead(hop: .userVisible, startup: order.startup, take: { [logger] read in
            DebugTimings.markLaunch("dfl.settings_wait")  // the read in hand: at once warm, after the disk cold
            if let failure = read.bootstrapFailure { logger.error("cmux-next config bootstrap failed: \(failure, privacy: .public)") }
            // cmux.json's appearance goes on the Ghostty overrides; the first config builds with them on a files lane and the launch goes on when it lands (p02-threads-129).
            TerminalThemeSetting.prime(read.snapshot)
        }, then: { [self] read in GhosttyRuntime.shared.start(loadingOn: GhosttyLaneConfigLoader(work: launchReads.work, mainWork: mainWork)) { [self] in finishLaunching(settings: read, launchStart: launchStart) } })
    }

    /// The launch steps that need the settings, run after the settings launch read's take (`applicationDidFinishLaunching`).
    private func finishLaunching(settings settingsRead: SettingsController.LaunchRead, launchStart: UInt64?) {
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
                                   launchImageHold: launchImageHold, launchStartup: order.startup, crashKeys: control.crashKeys,
                                   features: features)
        AppProcessRoot.shared.adopt(services)
        self.services = services
        controlSocket = AppControl.beginBind(features: services.features, settingsRead: settingsRead, launch: environment.launch,
                                             work: launchReads.work, mainWork: mainWork)  // p08-startup-019: on a lane
        TooltipPresenter.shared.appEvents = services.appEvents  // its inactive-app dismissal shares the app's one observer
        BrowserExternalApps.shared.queries = services.workspaceQueries  // a page's app links ask Launch Services on the system lane
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
        // screen) reveals at once and is interrupted: its first frame records no launch sample.
        let startup = mainWork.startup
        let presentation: StartupPhase.Presentation = NSApp.isHidden ? .hidden : .window
        startup.noteLaunch(presentation)
        if presentation != .window { DebugTimings.markLaunch(LaunchSlices.interruptedMark) }  // before the first window
        services.daemon.store.whenFirstSnapshotApplied { startup.markDone(.firstSnapshot) }
        // The restore and visible-page references are the pane refs' (`VisiblePaneRefs.finishRestore`).
        startupReferences.watchUnavailable { [daemon = services.daemon] in daemon.startup.isUnavailable }
        // Hangs, lag spikes and opt-in hang reports (WatchdogReporting); the controller lives with the process.
        AppProcessRoot.shared.adopt(hangReports: WatchdogReporting.install(control.watchdog, services: services))
        services.quit.watchdog = control.watchdog
        // Idle wakeups per inactive minute (p09-observability-059), once the launch's own work is done.
        order.startup.post(.afterStartup, "AppServices.startIdleWakeups", on: .main) { [weak services, control = self.control] in
            guard let services else { return }
            services.startIdleWakeups(watchdog: control.watchdog, hiddenWorkspaceMemory: AppProcessRoot.shared.hangReports?.memory)
            control.idleWakeups = services.idleWakeups  // the person's input ends an idle period at that input
        }
        DebugTimings.markReveal(services.launchReveal)
        // Debug Settings overrides (DEV and NIGHTLY only) before any window lays out.
        services.debugSettings.start()
        DebugTimings.markLaunch("dfl.services")
        AppActions.bindAtLaunch(services, on: order.startup)  // critical `AppActions.bind`: keys work from the first frame
        services.palettes.bindRegistryActions()  // the palette itself is built after the first frame, or by the first palette key
        let ghosttyKeybinds = GhosttyKeybindSync(router: services.keyRouter, launchImages: launchImageHold)
        self.ghosttyKeybinds = ghosttyKeybinds
        ghosttyKeybinds.start()
        let ghosttyConfigLiveReload = GhosttyConfigLiveReload(deadlines: services.mainDeadlines)
        self.ghosttyConfigLiveReload = ghosttyConfigLiveReload
        ghosttyConfigLiveReload.start()
        // App-scoped Ghostty actions (quit, toggle_visibility, ...) arrive with no surface. Inline before the restore: a
        // pane can mount before the first frame, and its key-equivalent path reads these hooks on every key.
        TerminalHooks(services: services).install()
        // The terminal key path's input-source switch keys, read off main now and on each activation.
        GhosttyRuntime.shared.inputSources.start(runner: services.work)
        GhosttyRuntime.shared.traceHook.deliverGPUCompletions(on: services.mainWork, to: FrameScheduler.appDisplays.presents)
        GhosttyRuntime.shared.followEnergySaver(on: services.mainWork)
        DebugTimings.markLaunch("dfl.bind")
        startSettingsAndControl(services: services, launch: settingsRead)
        DebugTimings.markLaunch("dfl.settings")
        MainMenu.install(registry: services.registry, blocking: services.blocking, on: order.startup)  // critical `MainMenu.make`
        DebugTimings.markLaunch("dfl.menu")
        HandlerCoverage.verifyAtLaunch(services.registry)  // every handler is bound by now; Debug builds only
        order.startup.post(.critical, "WindowActivation.activateApp", on: .main) { WindowActivation.activateApp() }
        launchSettle.install(daemon: services.daemon, warmup: services.agentPageWarmup, on: services.mainWork)
        // The painted terminal colors first (OSC 10/11/12), and the prompts' side-event subscriptions before the connect.
        daemonPrompts = services.startLocalDaemon(prestart: daemonPrestart)
        services.lifetimeFollowers.append(FeaturePolicyEnforcer(services: services).start())
        services.postCloudStart(on: order.startup)  // no Cloud restore or connect before the first frame (p08-startup 020)
        services.postNonPaintServices(on: order.startup)
        // Before the first window opens (restoreWhenLoaded opens one at once): its indicators and its first
        // become-main notice find the config and resync follows running.
        StatusIndicatorAppearance.shared.observe(on: services.mainWork, appEvents: services.appEvents,
                                                 workspaceEvents: services.workspaceEvents)
        services.windows.onPresent = { [weak services] controller in
            DebugTimings.markLaunch("first_window_presented")  // launch.first_window ends here (once per process)
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
            CATransaction.setMainCompletion { [weak self] in
                DebugTimings.markLaunch("first_window_frame_committed")
                self?.order.startup.firstFrameCommitted()
            }
        }
        // Once startup completes (the visible page loaded, the launch images went), one idle frame each: the palette's
        // panel and command page, so the first open costs what later opens cost (a launcher panel opens in
        // one frame); then the icon picker (its panel, page and symbol catalog), so the first Set Icon opens
        // warm; then the system file picker made ahead, so the first click is not cold.
        LaunchFirstOpenWarmups(paletteSteps: PaletteController.prepareStepNames, prewarmPaletteStrings: { PaletteController.prewarmStrings() },
                               preparePalette: { [weak services] in _ = services?.palette.prepare(step: $0) },
                               prepareIconPicker: { [weak services] in services?.iconPicker.prepare() },
                               warmOpenPanel: { [weak services] in services?.openPanel.warmWhenIdle() }).post(on: order.startup)
        services.palettes.postBuild(on: order.startup)
        // Temporary download files a crash left in an earlier run (only the
        // recorded ones; the record is read and the files deleted off the
        // main actor). Downloads of this run are never touched.
        launchCleanup.schedule(on: order.startup)
        services.iconPicker.onOpened = { DebugTimings.iconPickerOpened($0) }
        let profilesDirectory = BrowserProfileService.defaultDirectory(bundleID: services.environment.launch.bundleID)
        services.browserProfiles.load(directory: profilesDirectory, importStore: services.onboarding.importStore)
        DebugTimings.markLaunch("dfl.first_window_hooks")
        services.home.startWorkspace()  // the restore's first workspace waits for ensure_home; the Chief owner is a feed post
        order.startup.post(.afterFirstFrame, "MouseSideButtons.start", on: .main) { [weak self, weak services] in
            self?.mouseSideButtons.start { [weak services] in _ = services?.registry.perform($0 == .back ? "focusHistoryBack" : "focusHistoryForward") }
        }
        order.startup.post(.afterFirstFrame, "KeybindingsFile.start", on: .main) { [weak services] in services?.keybindingsFile.start() }
        services.bookmarks.start(directory: profilesDirectory, importStore: services.onboarding.importStore)
        services.history.start(supportDirectory: profilesDirectory.deletingLastPathComponent())
        // cmux-page:// first-party pages for Chromium, before any window can start it.
        FirstPartyPageSchemes.install(processGroups: services.features.isEnabled(.pageProcessGroups), rendererSharing: services.features.isEnabled(.cmuxPageRendererSharing))
        let spareAfterFirstTab = services.features.isEnabled(.chromiumSpareAfterFirstTab)
        services.cache.cef.spareAfterFirstTab = { spareAfterFirstTab }
        services.cache.cef.setAdBlockerAtFirstTab(services.features.isEnabled(.chromiumAdBlockerAtFirstTab))
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
        // The runtime pack check wires the engine reason at once; its download waits until asked.
        services.startChromiumRuntime()
        services.postLaterTabWarmups(on: order.startup)
        // Other apps' sign-ins, before any request a launch by one delivers.
        // The engines' incognito profiles and the Chromium engine's sign-in tabs (AppServices).
        let webAuthWindows = WebAuthSessionWindows(host: services, logger: services.daemon.logger,
                                                   profiles: services.browserStores.offTheRecord, signInCallbacks: services.signInCallbacks,
                                                   contextMenus: services.contextMenus, mainWork: services.mainWork, inputTap: services.inputTap)
        let webAuthHandler = WebAuthSessionHandler(broker: WebAuthSessionBroker(opener: webAuthWindows))
        self.webAuthHandler = webAuthHandler
        WebAuthSessionHandler.install(webAuthHandler)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        services.windows.onContentDidAppear = { [weak services] in services?.externalOpen.flush(); services?.pageHostPool.windowDidAppear($0.window); AppProcessRoot.shared.hangReports?.memory?.workspaceDidShow() }
        NSApp.servicesProvider = CmuxServicesProvider(open: services.externalOpen)
        launchOpens.release { item in  // services exist now: nothing is held while this runs
            switch item {
            case .url(let url): routeOpenedURL(url)
            case .activity(let type, let webpageURL): _ = services.externalOpen.continueActivity(type: type, webpageURL: webpageURL)
            }
        }
        // The registered launch work ends the implicit ref. The first window is made in this turn
        // (`restoreWhenLoaded`), so its commit ends the first-frame ref; a launch that shows none
        // completes at the scheduler's failsafe, with reason `failsafe`.
        order.startup.finishRegistration()
        DebugTimings.markLaunch("did_finish_launching_end")
        DebugTimings.armFirstIdleMark()
        if let launchStart { startupTrace?.task("did_finish_launching", start: launchStart) }
    }

    /// cmux-next.json settings and the tagged control socket (`action.list/describe/run`) over the same registry.
    private func startSettingsAndControl(services: AppServices, launch: SettingsController.LaunchRead) {
        // Start the web OTA launch check before any restored or prewarmed page can
        // request its entry document. Otherwise the entry can come from the app
        // bundle while later chunks come from the kept update tree.
        WebUpdates.shared.prepare(
            launch.snapshot.updates, bundle: .main, files: services.work, energy: services.mainWork.energy,
            shown: services.features.isEnabled(.hiddenPollPause) ? services.appVisibility.shownWindows : nil)
        let registry = services.registry
        let settings = SettingsController(registry: registry, fileURL: launch.fileURL, launch: launch)
        // Managed-settings status for MDM tooling (osquery, Fleet, Jamf), plans/cmux-next/enterprise.md: written on the files lane after startup.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // One sequence: each write replaces the file, so a later status must never land before an earlier one.
        let statusWrites = services.work.sequence("settings.managed-status")
        settings.writeManagedStatus(to: ManagedStatusReport.defaultURL(bundleID: bundleID),
                                    context: ManagedStatusReport.Context(appVersion: version, bundleID: bundleID)) { [startup = order.startup] write in
            startup.post(.afterStartup, "Settings.writeManagedStatus", on: .sequence(statusWrites, .bestEffort), write)
        }
        settings.applyManagedFeaturesNow()
        settings.adoptLaunchRead()  // the first load from the launch read, no file call: the first frame is in the file's look
        services.lifetimeFollowers += ManagedPolicyBridge(settings: settings, updater: services.updater, auth: services.cloudAuth, mainWork: services.mainWork, appEvents: services.appEvents).start()
        self.settings = settings
        services.settings = settings
        // No socket write asks for a confirmation before the first frame: the control socket starts after it.
        order.startup.post(.afterFirstFrame, "UserOnlySettingConfirmation.install", on: .main) { [weak settings, weak services] in
            if let settings, let services { UserOnlySettingConfirmation.install(settings, services: services) }
        }
        // macOS posts no notification when an MDM profile changes: activation is the backstop next to the managed-file watchers.
        order.startup.post(.afterFirstFrame, "Settings.followActivation", on: .main) { [weak settings, events = services.appEvents] in
            settings?.followActivation(on: events)
        }
        // Every palette-exposed schema setting in the palette (R93), and the recorder's writes; neither builds the palette.
        order.startup.post(.afterFirstFrame, "Palette.settingsSource", on: .main) { [weak services, weak settings] in
            guard let services, let settings else { return }
            services.palettes.sources.settings = SettingsPaletteSource(settings: settings, themes: services.themes.catalog) { [weak services] in
                services?.windows.active.map { SettingsPaletteSource.themeColors($0.themeScope.tokens) } ?? []
            }
            services.paletteShortcutEditor = PaletteShortcutEditor(services: services, settings: settings)
        }
        // Neither the first frame nor a page engine reads these (p08-startup-028).
        LaunchServicePosts.browserFollows(historyDaemonSync: { [weak services] in services?.history.startDaemonSync(settings: settings) },
                                          locationTrailScope: { [weak services] in services?.locationTrail.watchScope(settings: settings) }).post(on: order.startup)
        // The file watches and the diagnostic toasts; the launch read is applied above, and the start reloads once.
        order.startup.post(.afterFirstFrame, "Settings.start", on: .main) { [weak settings] in settings?.start(announcingDiagnostics: true) }
        AppProcessRoot.shared.hangReports?.recordUserWrites(of: settings)  // the person's own consent, from the first write on
        order.startup.post(.afterStartup, "HangReports.start", on: .main) { [weak settings, asks = services.machineAsks, startup = order.startup] in
            if let settings { AppProcessRoot.shared.hangReports?.start(settings: settings, asks: asks, firstWindow: { await startup.afterFirstFrame() }) }
        }
        // An attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) keeps its owner's chat settings.
        let acpmux = QuitAgents.environment(services)
        services.lifetimeFollowers += ChatSettingsPush.start(settings: settings, socketPath: acpmux?.isAttached == true ? nil : acpmux?.socketPath, on: services.mainWork)
        // The platform services: what the first frame or the restore reads now, the rest posted (p08-startup-029).
        services.startPlatformServices(settings: settings, on: order.startup, hotKeys: !environment.isolatedLaunch)
        services.followEnergySaver(settings)
        // `launch.savedPicture` off deletes the saved window pictures at once, not at the next quit (p08-startup 3C).
        if let pictures = services.environment.windowPictures {
            services.lifetimeFollowers.append(pictures.followSavedPicture({
                settings.loadCount >= 1 ? settings.snapshot.savedPicture : nil
            }, on: services.mainWork))
        }
        // A page's chat clicks and All chats pages work from its first frame; the feeds come after it (p08-startup-027).
        AgentPageChats.wirePager(services.agentTabs, environment: acpmux, opener: services.chatsOpener)
        services.home.postLaunchFeeds(startup: order.startup)
        // The GitHub connection is deliberately off by default. Changes in
        // Settings apply to the one feed owner and never create a second
        // inbox store.
        order.startup.post(.afterStartup, "FeedGitHub.follow", on: .main) { [weak services, weak settings] in
            guard let services, let settings else { return }
            services.lifetimeFollowers.append(ServiceObservation(.background, owner: "FeedGitHub.setting", on: services.mainWork) {
                settings.snapshot.feedGitHub
            } apply: { [weak services] github in
                services?.configureFeedGitHub(enabled: github.enabled, pollIntervalSeconds: github.pollIntervalSeconds)  // builds no feed
            })
        }
        order.startup.post(.afterFirstFrame, "ConfigActions.start", on: .main) { [weak services, weak settings] in
            if let settings { services?.configActions.start(settings: settings) }  // cmux.json's custom actions for the palette and menus
        }
        // What an engine reads when it makes a page or starts, before any does (managed policy included).
        services.cache.browserTabs.preference.follow(settings, on: services.mainWork)
        services.lifetimeFollowers += BrowserLinkClickPreference.follow(settings, webKit: services.cache.webKit, chromium: services.cache.chromium, on: services.mainWork)
        order.startup.post(.afterFirstFrame, "WorkspaceAutoName.start", on: .main) { [weak services, weak settings] in
            if let services, let settings { WorkspaceAutoNameWiring(services: services).start(settings: settings) }  // `workspaces.autoName.variant` persist (hq#1957)
        }
        services.lifetimeFollowers += BrowserOmnibarPreference.follow(settings, cache: services.cache, on: services.mainWork)
        // The look of the first frame: the loaded theme, background and backdrop art, then each workspace's theme and the app accent.
        order.startup.post(.critical, "TerminalTheme.follow", on: .main) { services.terminalTheme.follow(settings) }
        order.startup.post(.critical, "Themes.start", on: .main) { services.themes.start(); services.themes.followChromeTheme(settings) }
        services.bookmarks.follow(settings)
        // controlSocketEarlyBind: the control posts, after the first frame (p08-startup-019).
        control.postLaunch(socket: controlSocket, order: order, services: services, settings: settings, launch: environment.launch, logger: logger)
        Task {
            await settings.waitForLoad(atLeast: 1); await launchSettle.settled(within: .seconds(4), images: launchImageHold) // without controlSocketEarlyBind, the control socket starts here (cx-z9kz0)
            // `app.quitBehavior: "end"` (first release) is now "end-keep-layout".
            _ = try? await settings.migrateLegacyQuitBehavior()
            _ = try? await settings.migrateLegacyWorkspaceRowKeys() // `sidebar.showWorkspaceDirectory` / `showCounts` move to `sidebar.workspaceRow.*`
            _ = try? await settings.migrateLegacyPaneToolbarButtons() // `tabs.hiddenButtons` becomes `tabs.toolbarButtons`
            // Classic cmux keys next reads under another name (`ClassicSettingRename`).
            _ = try? await settings.migrateClassicSettings()
            // Shortcuts and settings classic cmux's Settings kept in its preferences (`ClassicShortcutImport`, `ClassicPreferenceImport`).
            _ = try? await settings.importClassicShortcuts(marker: .standard)
            _ = try? await settings.importClassicPreferences(marker: .standard)
            control.runAfterSettle(socket: controlSocket, services: services, settings: settings, launch: environment.launch, logger: logger)
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
        guard let services else {
            // Before the services exist (the settings read in flight): kept, then continued by the launch.
            guard userActivity.activityType == NSUserActivityTypeBrowsingWeb else { return false }
            launchOpens.hold(.activity(type: userActivity.activityType, webpageURL: userActivity.webpageURL))
            return true
        }
        return services.externalOpen.continueActivity(type: userActivity.activityType, webpageURL: userActivity.webpageURL)
    }

    /// One route for every URL macOS hands cmux (`OpenedURLRouting`): the
    /// sign-in callback to Cloud auth first, in every form auth accepts,
    /// then `ExternalOpenRouter`.
    private func routeOpenedURL(_ url: URL) {
        guard let services else { return launchOpens.hold(.url(url)) }  // routed when the launch builds them
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
        services?.madeSSH?.stop()
        services?.serverReach.stop()
        controlSocket?.discard()  // a socket bound at launch that never served
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
