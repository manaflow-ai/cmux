import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextChromiumRuntime
import CmuxNextCloud
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHomeEngine
import CmuxNextIcons
import CmuxNextInput
import CmuxNextIPC
import CmuxNextLaunch
import CmuxNextMallocZone
import CmuxNextRemoteFetch
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextCompat
import CmuxNextTrace
import CmuxNextWakeups
import CmuxNextWebUpdates

/// Entry point called from the Xcode target's `App/main.swift`.
public struct CmuxNextApp {
    public static let shared = Self()
    public func main() {
        // First: the launch's one watchdog and the startup tag it reads, so every launch stall is
        // listed with its phase and step (Chrome makes its HangWatcher at process start: base/threading/hang_watcher.h).
        // Its thread starts below, once the process may have a second one; it measures from here.
        let startupTag = StartupTaskTag()
        // The one-thread steps up to the watchdog's start: one step, since a stall in them is listed only at the start.
        startupTag.step("main.one_thread")
        // The main thread's one deadline queue (its run-loop timer stays parked until the first deadline; no thread):
        // the watchdog's busy windows end on it, and the scheduler LaunchOrder makes below shares it.
        let mainWakeUps = MainWakeUpQueue(energy: EnergyPolicySource())
        let watchdog = MainThreadWatchdog(startupTasks: startupTag, wakeUps: mainWakeUps)
        // CMUX_TRACE_STARTUP: the startup trace's ring, before the first mark (unset: one getenv, no ring).
        let startupTrace = DebugTimings.makeStartupTrace()
        DebugTimings.markLaunch("main_start")
        announceBenchHooksBuild()
        // First, while the process has one thread: install the delegating
        // default malloc zone Chromium expects (Chromium's
        // EarlyMallocZoneRegistration). The Chromium framework is mapped
        // later on a background thread; its PartitionAlloc constructor then
        // swaps zones without a moment where no zone owns system memory.
        // Without this, a free() on another thread in that moment crashed
        // with "No zone found" (browser-isolation.md, allocator zone race).
        // A sanitizer build keeps Chromium unloaded, so it needs no such zone (SanitizerRuntime).
        if SanitizerRuntime.detect(environment: ProcessInfo.processInfo.environment).loadsChromium {
            _ = cmux_early_malloc_zone_registration()
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        // CMUX_NEXT_MAIN_JOB_CENSUS=1 (startup-queue.py mainjobs): every main job and turn until startup completes.
        // Its hook goes in while the process still has one thread, before any main-actor job.
        let mainJobs = MainJobCensus.armed(environment: ProcessInfo.processInfo.environment, processStartNanos: DebugTimings.processStartUptimeNanos)
        // CMUX_NEXT_GLOBAL_JOB_CENSUS=1 (startup-queue.py globaljobs): every task that starts on the cooperative pool
        // until startup completes, its hook in before the launch starts tasks.
        let globalJobs = GlobalJobCensus.armed(environment: ProcessInfo.processInfo.environment, processStartNanos: DebugTimings.processStartUptimeNanos)
        // CMUX_NEXT_ARM_CENSUS=1 (startup-queue.py arms): each timer, deadline and folder watch armed until startup
        // completes, with its first fire.
        let armCensus = WakeupLedger.shared.armCensus
        armCensus.start(environment: ProcessInfo.processInfo.environment, processStartNanos: DebugTimings.processStartUptimeNanos)
        #endif
        // Before any socket or pipe exists (ChildSignalDefaults); the open-file limit before CefInitialize
        // (OpenFileLimit: launchd's 256 stopped the app at 80-100 Chromium tabs).
        ChildSignalDefaults.installAppSignalPolicy(); let openFiles = OpenFileLimit().raise()
        // Before any thread starts or anything reads the environment: drop
        // cmux variables inherited from a shell inside another cmux, so they
        // cannot pick this app's socket, tag, or daemon session.
        // A debug build's sign-in choice (CMUX_AUTH_CREDENTIALS_FILE and friends) is kept for CloudAuth only.
        CloudAuth.captureLaunchEnvironment()
        // This process's only environment writes, then the freeze: a write
        // after it stops a debug build (ProcessEnvironmentGuard).
        Self.prepareLaunchEnvironment()
        DebugTimings.markLaunch("main.environment_frozen")
        // ghostty_init while the process still has one thread: its locale setup may setenv LANG and setlocale
        // (Ghostty's internal_os.ensureLocale, src/os/locale.zig), which must not race another thread's environ read.
        GhosttyRuntime.initializeLibrary()
        // The launch's second thread: the one-thread steps above count from the watchdog's creation.
        watchdog.start(measuringSinceCreation: true)
        // Pure launch work (action catalog, symbols, displays, icons) overlaps AppKit's start; the registry takes the catalog.
        watchdog.startupStep("main.warmup")
        let actionCatalog = ActionCatalogLaunch()
        LaunchWarmup(work: { if actionCatalog.build() { DebugTimings.markLaunch("action_catalog_built") } },
                     decodeIcons: { IconPack.decodeBundledInBackground(then: $0) }, markLaunch: { DebugTimings.markLaunch($0) }).start()
        DebugTimings.markLaunch("main.warmup_started")
        watchdog.startupStep("main.lanes")
        // One hang watch for the process: the lanes, the daemon readers and the terminal output lanes.
        let hangWatch = TraceRuntime.shared.hangWatch
        // The main task board, shared by the lanes (an awaited low item in an input turn is a Debug site) and the budget.
        let mainBoard = MainTaskBoard()
        // The launch's file reads run on these lanes, never on the main thread (p08-startup 033).
        let work = BackgroundWork(hangs: hangWatch, onRan: startupTrace?.laneJobSink, inputTurns: mainBoard)
        // Idle and best-effort lane work waits for the reveal (Chrome's BeginBestEffortFence); the order made on it lowers it.
        let fence = LaunchOrder.BestEffortFence(raisingOn: work)
        startupTrace?.start(writingOn: work) // its file is written on work's files lane, never here
        startupTrace?.whenClosed { work.stopReportingRuns() } // a closed trace costs the lanes nothing
        // Shells get the launch limit back. Path lookups only: the stores at these paths read and create on first use.
        watchdog.startupStep("main.environment")
        var environment = AppEnvironment.current(openFiles: openFiles)
        environment.marksRun = true
        environment.actionCatalog = actionCatalog
        // The launch caches' crash-streak decision, made on the files lane by the first cache read or
        // the run marker's launch read, which writes this launch's record before any cache is read: after a streak of
        // launches that ended before their startup completed, every launch cache below reads as missing.
        let markerFolder = AppRunMarker.standardDirectory(bundleID: environment.launch.bundleID), launched = Date()
        let launchCaches = LaunchSafeMode.Gate(decide: { AppRunMarker.launchSafeMode(directory: markerFolder, now: launched) },
                                               mark: { DebugTimings.markLaunch($0) })
        environment.launchCaches = launchCaches
        let cacheReader = environment.launchCacheReader
        #if DEBUG || CMUX_BENCH_HOOKS
        environment.mainJobCensus = mainJobs
        environment.globalJobCensus = globalJobs
        #endif
        // Key flows start and stop at run time; CMUX_NEXT_TRACE_FLOWS only starts them at launch.
        TypingLatencyProbe.shared.startFlows(launchEnvironment: ProcessInfo.processInfo.environment)
        environment.sidebarSnapshotFile = SidebarSnapshotFile.standard(launch: environment.launch)
        environment.layoutTemplatesFile = environment.sidebarSnapshotFile?.url.deletingLastPathComponent().appending(path: "layout-templates.json")
        let homeCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        environment.homeCachesDirectory = homeCaches
        // The Home list's caches of this build's Chief owner, read on the files lane while AppKit starts.
        environment.homeListRead = HomeListLaunchRead.start(owner: ChiefHome.resolve(tag: environment.tag).session, caches: homeCaches, on: work,
                                                            reads: { launchCaches.safeMode.readsLaunchCaches })
        // The app's acpmux, resolved once on the system lane: its signature check reads this app's signing team
        // (SigningTeamInstall) and hashes the binary. Main-thread users take the landed answer (QuitAgents.environment).
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        let processVariables = ProcessInfo.processInfo.environment, build = environment.build
        environment.appAcpmux = LaunchRead(on: work, mayBlock: .system) {
            AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: bin, environment: processVariables)
        }
        DebugTimings.markLaunch("main.app_environment")
        // The last quit's agent pages, terminal frames and chat composers are read and decoded off the main thread
        // from here, while AppKit starts, so each pane's first frame can use them without waiting. Where each chat
        // rests and its unsent chips are kept beside them too (AgentPaneChatStores, made with the agent tabs).
        let state = environment.sidebarSnapshotFile?.url.deletingLastPathComponent()
        // Ghostty's resources folder, CLI helper and terminfo (a few stats), before the other launch reads on the
        // files lane: every shell's env and the daemon's start await it.
        watchdog.startupStep("main.launch_reads")
        environment.ghosttyProbe = GhosttyLaunchProbe.start(on: work)
        // The incognito workspaces a crashed run left, then the settings read, in one sequence: the launch window
        // (made after the settings read lands) knows whether it may list every workspace (p08-startup 038).
        let ledgerThenSettings = work.sequence("launch.ledger-then-settings")
        environment.incognitoLeftovers = IncognitoWorkspaceLedger.startLaunchRead(
            at: IncognitoWorkspaceLedger.standardURL(bundleIdentifier: Bundle.main.bundleIdentifier), in: ledgerThenSettings)
        // The Labs page's local feature choices (DEV and NIGHTLY), first in that sequence: the launch's features take
        // them when this read has ended by the time they resolve (components/flags_ui, applied at start).
        if Feature.Channel(environment.build.kind).allowsLocalOverrides {
            let file = SidebarSnapshotFile.buildDirectory(launch: environment.launch)
                .appending(path: "features", directoryHint: .isDirectory).appending(path: FeatureLocalOverrides.fileName)
            environment.featureLocalOverridesFile = file
            environment.featureLocalOverrides = LaunchRead(in: ledgerThenSettings, dropped: FeatureLocalOverrides()) { FeatureLocalOverrides.read(file) }
            // The Debug tunables features replace (`browserResize.layerHosting`) are their local overrides too: read
            // from the build's debug-tunables.json in the same sequence, never through the tunable store's later load.
            if let tunables = DebugSettingsService.launchFile(launch: environment.launch, environment: ProcessInfo.processInfo.environment) {
                let keys = FeatureLaunchLocalOverrides.replacedKeys(of: Feature.registered)
                environment.featureTunableOverrides = LaunchRead(in: ledgerThenSettings, dropped: [:]) { TunableFile.boolValues(tunables, keys: keys) }
            }
        }
        // The run marker reads the last run's files and opens this run's, after the Labs and tunables
        // reads (the launch's features take those without waiting) and before the settings read: the services, made
        // after the settings read lands, take its result with no file call on main.
        environment.runMarker = AppRunMarker.startLaunchRead(directory: markerFolder, in: ledgerThenSettings, now: launched, gate: launchCaches)
        // The saved sidebars, before the settings read: the launch window's first frame draws them.
        environment.sidebarSnapshot = environment.sidebarSnapshotFile?.startLaunchRead(in: ledgerThenSettings, reader: cacheReader)
        // This Mac's install id, after the feature choices (the launch's features do not wait for it) and after the run marker
        // and saved sidebars, before the settings read: the windows built when that lands find it read.
        let cloudPaths = CloudPaths.standard(bundleID: Bundle.main.bundleIdentifier)
        let deviceID = LaunchRead(in: ledgerThenSettings, dropped: .failure(.notReadYet)) { cloudPaths.deviceIDResult() }
        environment.cloudDeviceID = CloudDeviceIDSource(paths: cloudPaths) { deviceID.value }
        // cmux-next.json (made on first launch) read and merged with the managed layers on the files lane, next:
        // the launch steps that need it run when it lands, never waiting for it on main (p08-startup 025).
        let settingsRead = SettingsController.startLaunchRead(on: work, in: ledgerThenSettings)
        let launchImages = AgentPaneLaunchImages(state: state, reader: cacheReader), relaunchWake = AgentPaneRelaunchWake(directory: state)
        launchImages.prefetch(on: work) { DebugTimings.markLaunch($0) }
        let terminalFrames = TerminalLaunchFrames(state: state, reader: cacheReader)
        terminalFrames.prefetch(on: work) { DebugTimings.markLaunch($0) }
        environment.browserLaunchPictures = BrowserLaunchPictures(state: state, work: work, reader: cacheReader)  // browser pages'
        environment.browserLaunchPictures?.prefetch { DebugTimings.markLaunch($0) }
        environment.windowPictures = WindowPictureStore(state: state, work: work, reader: cacheReader)  // the windows'
        relaunchWake.begin(on: work)
        // The kept web update's state and digest (NIGHTLY): pages wait for it, never main.
        environment.webUpdates = WebUpdates.startLaunchRead(on: work)
        // The browser source registry (browser-sources.json) the import pickers and the Passwords page read:
        // in memory before them, never read on the thread that asks first.
        BrowserSourceRegistryInstall.shared.load(on: work)
        // This app's signing team, which every acpmux resolve and the Computer Use admission require: asked of
        // securityd on the system lane, so a main-thread resolve reads it from memory.
        work.post(.userVisible, mayBlock: .system) { SigningTeamInstall.process.load() }
        DebugTimings.markLaunch("main.launch_reads")
        // Tab favicons resolve their hosts on work's host-resolution slots (system lane), never on the pool;
        // video wallpapers list the windows above theirs on its system lane, never on main.
        BrowserFaviconLoader.shared.useResolver(SystemRemoteResolver(runner: work))
        BackdropVideoPlayers.shared.lanes = work
        // The launch's feature values, once, before the first feature read (the daemon connect's).
        watchdog.startupStep("main.daemon_prestart")
        let features = AppServices.launchFeatures(environment)
        if features.isEnabled(.terminalLaunchPrefetch) { TerminalLaunchPrefetch().start() }
        // What every hello tells the local daemon, which outlives this app.
        environment.daemonFeatureHello = DaemonFeatureHello(hash: features.daemonValuesHash, values: Dictionary(
            features.daemonValues.map { ($0.name, $0.isEnabled) }, uniquingKeysWith: { _, last in last }))
        // `debug.daemon.wire`'s counters, each schema method timed; nil in a release build unless the
        // person opted in to field data.
        let wireStats = DaemonWireStats.forBuild(fieldData: features.isEnabled(.ipcMethodLatencyFieldData),
                                                 methods: MethodTable.schema.methods.map { .init(id: $0.id.rawValue, name: $0.name) })
        // The daemon connect overlaps AppKit's start, all of it on the system lane: this app's signature first
        // (the launcher's install key needs the Team ID), then the launcher and its first attempt. The daemon's
        // launch snapshot is read and decoded on the files lane from there, once the launcher names its session;
        // the daemon's start applies it. A read quit drops before it started ends as `.missing`,
        // so nothing waits for it.
        let launch = environment.launch, terminalEnvironment = environment.terminalEnvironment
        let resolvedTerminalEnvironment = environment.resolvedTerminalEnvironment()
        let terminalEnvironmentProvider = environment.terminalEnvironmentProvider()
        let resolvesShellIntegration = environment.resolvesShellIntegration, echoesPlacementShift = SidebarMirror.isLinked
        let featureHello = environment.daemonFeatureHello, terminalStreams = Self.terminalStreams(features)
        let daemonStart = LaunchRead<DaemonLaunchStart>(on: work, mayBlock: .system) {
            let start = DaemonService.launchStart(work: work, launch: launch, terminalEnvironment: terminalEnvironment,
                                                  resolvedTerminalEnvironment: resolvedTerminalEnvironment,
                                                  terminalEnvironmentProvider: terminalEnvironmentProvider,
                                                  resolvesShellIntegration: resolvesShellIntegration,
                                                  echoesPlacementShift: echoesPlacementShift, wireStats: wireStats, hangWatch: hangWatch,
                                                  featureHello: featureHello, terminalStreams: terminalStreams)
            guard let names = start.snapshotNames else { return start }
            let read = LaunchRead(on: work, dropped: LaunchSnapshot.Found.missing) {
                launchCaches.safeMode.readsLaunchCaches ? LaunchSnapshot.find(session: names.session, stateDirectory: names.stateDirectory) : .missing
            }
            return start.reading(LaunchSnapshotPrefetch(session: names.session, ended: { read.value }, finished: { await read.finished() }))
        }
        DebugTimings.markLaunch("main.prestart")
        // The front window's picture for the first frame, read and decoded on the files lane;
        // which window is front comes from the launch snapshot, read there only when a picture was saved.
        if features.isEnabled(.savedWindowPicture) {
            let build = environment.launch.build
            environment.windowPictures?.prefetchFront({
                guard launchCaches.safeMode.readsLaunchCaches else { return nil }  // the launch snapshot is a launch cache
                // The daemon's launch step when it has landed, else this build's daemon names read here by the
                // launcher's rule (DaemonLauncher.appNames): the picture's read never waits for the system lane.
                let landed = daemonStart.value
                let names: (session: String, stateDirectory: URL?)? = if let landed { landed.snapshotNames } else {
                    DaemonLauncher.appNames(build: build)
                }
                guard let names else { return nil }
                // The snapshot's read when it has ended, else read here: the picture's read never waits for it.
                let found = landed?.launchSnapshot?.found ?? LaunchSnapshot.find(session: names.session, stateDirectory: names.stateDirectory)
                // The window `LaunchSnapshotWindow.showSaved` builds, by the same rule (WindowStateDocument.frontWindow).
                return found.snapshot?.frontWindow.map {
                    WindowPictureStore.FrontWindow(window: $0.id, profile: ($0.profile ?? .defaultProfile).rawValue)
                }
            }, mark: { DebugTimings.markLaunch($0) })
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        // CMUX_NEXT_BENCH_LAUNCH_STALL_MS: a main-thread stall before NSApp, which bench-launch-stall.py finds in debug.hangs.
        watchdog.startupStep("bench.launch_stall")
        BenchLaunchStall(environment: ProcessInfo.processInfo.environment).run()
        #endif
        watchdog.startupStep("main.nsapp")
        // DEV and NIGHTLY crash at an exception's throw site (cx-r3q), before NSApp exists.
        CrashOnExceptions.register()
        // Instantiate the CEF-ready subclass before anything touches NSApp.
        let app = CmuxApplication.shared
        (app as? CmuxApplication)?.refusesActivation = environment.noActivate // CMUX_NEXT_NO_ACTIVATE=1, read once above
        // The launch's order owners: the main-thread scheduler and the StartupScheduler on it, passed by init.
        // The one input tap (p04-input.md 3 (A)): the budget's pending input, control and services observe it.
        let inputTap = InputEventTap()
        // The design kit's popups, overlay hosts and tooltip subscribe to it too, before the delegate
        // and services make any: their owners in many packages make them with no tap.
        WindowOverlayHost.appInputTap = inputTap
        TooltipPresenter.shared.inputTap = inputTap
        watchdog.startupStep("main.launch_order")
        let order = LaunchOrder(fence: fence, board: mainBoard, input: inputTap, startupTag: startupTag, wakeUps: mainWakeUps,
                                budgetPlacement: features.isEnabled(.mainBudgetTurn) ? .afterCommit : .inTick) { DebugTimings.markLaunch($0) }
        // Main-actor jobs by task priority (decision-gated; feature mainExecutorHook, default off).
        order.mainWork.installMainExecutorHook(requested: MainExecutorHook.isRequested(feature: features.isEnabled(.mainExecutorHook),
                                                                                      environment: ProcessInfo.processInfo.environment))
        // Main-actor jobs wait behind pending input; installed as `debug.mainJobGate` says (AppServices.settings).
        // Classed main work (post(class:), MainNotificationObserver) waits behind the same input.
        if features.isEnabled(.mainJobGate), let pending = order.mainWork.budget.pendingInput as? SessionInputPending {
            (app as? CmuxApplication)?.jobGate = MainJobGateSwitch(pending: pending, holding: order.mainWork)
        }
        DaemonLauncher.captureLoginEnvironment(after: order.startup) // at once only with nothing remembered
        #if DEBUG || CMUX_BENCH_HOOKS
        mainJobs?.freeze(after: order.startup)
        globalJobs?.freeze(after: order.startup)
        armCensus.close(after: order.startup)
        #endif
        LaunchThreadCensus.post(on: order.startup) { LaunchMarkSink.shared.writeValue(name: $0, value: $1) } // Debug/bench: threads at the first frame
        if let pictures = environment.windowPictures { order.startup.whenComplete { _ in pictures.dropFront() } } // decoded pictures are large
        let delegate = AppDelegate(environment: environment, daemonStart: daemonStart, wireStats: wireStats, features: features,
                                   startupTrace: startupTrace, order: order, watchdog: watchdog, inputTap: inputTap, settingsRead: settingsRead,
                                   launchReads: (work, launchImages, terminalFrames, relaunchWake))
        DebugTimings.markLaunch("main.delegate")
        // Every main run-loop turn is timed and split on the main-thread scheduler's meter (MainTurnMeter).
        (app as? CmuxApplication)?.meterTurns(delegate.turnMeter)
        // The one input tap hears every event from the first (pending input, control, services).
        (app as? CmuxApplication)?.inputTap = delegate.inputTap
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        DebugTimings.markLaunch("main.nsapp")
        DebugTimings.markLaunch("main.run")
        DebugTimings.armRunLoopStartMark()
        watchdog.startupStep("main.run") // AppKit's own start, up to applicationDidFinishLaunching
        // NSApplication.delegate is weak; keep the delegate alive for the run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// This Mac as the sizing device of the local daemon connection's terminal streams while feature
    /// `terminalStreams` is on: its terminal views then attach as streams on that connection,
    /// for the prestart's first connect and `AppServices.startLocalDaemon`'s. Nil keeps a connection per view.
    nonisolated static func terminalStreams(_ features: FeatureList) -> TerminalStreamsDevice? {
        guard features.isEnabled(.terminalStreams) else { return nil }
        return { await DaemonTerminalIO.sizingDevice.value }
    }
}
