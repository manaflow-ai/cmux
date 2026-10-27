import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
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

/// Entry point called from the Xcode target's `App/main.swift`.
public struct CmuxNextApp {
    public static let shared = Self()
    public func main() {
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
        _ = cmux_early_malloc_zone_registration()
        #if DEBUG || CMUX_BENCH_HOOKS
        // CMUX_NEXT_GLOBAL_JOB_CENSUS=1 (startup-queue.py globaljobs): every task that starts on the cooperative pool
        // until startup completes (p08-startup-082), its hook in before the launch starts tasks.
        let globalJobs = GlobalJobCensus.armed(environment: ProcessInfo.processInfo.environment, processStartNanos: DebugTimings.processStartUptimeNanos)
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
        // Pure launch work (action catalog, symbols, displays) overlaps AppKit's start.
        LaunchWarmup.start()
        DebugTimings.markLaunch("main.warmup_started")
        // One hang watch for the process: the lanes, the daemon readers and the terminal output lanes.
        let hangWatch = TraceRuntime.shared.hangWatch
        // The main task board, shared by the lanes (an awaited low item in an input turn is a Debug site) and the budget.
        let mainBoard = MainTaskBoard()
        // The launch's file reads run on these lanes, never on the main thread (p08-startup 033).
        let work = BackgroundWork(hangs: hangWatch, onRan: startupTrace?.laneJobSink, inputTurns: mainBoard)
        // Idle and best-effort lane work waits for startup complete, 3 s at most (Chrome's BeginBestEffortFence); the order made on it lowers it.
        let fence = LaunchOrder.BestEffortFence(raisingOn: work)
        startupTrace?.start(writingOn: work) // its file is written on work's files lane, never here
        startupTrace?.whenClosed { work.stopReportingRuns() } // a closed trace costs the lanes nothing
        // Shells get the launch limit back. Path lookups only: the stores at these paths read and create on first use.
        var environment = AppEnvironment.current(openFiles: openFiles)
        environment.marksRun = true
        #if DEBUG || CMUX_BENCH_HOOKS
        environment.globalJobCensus = globalJobs
        #endif
        // Key flows start and stop at run time; CMUX_NEXT_TRACE_FLOWS only starts them at launch.
        TypingLatencyProbe.shared.startFlows(launchEnvironment: ProcessInfo.processInfo.environment)
        environment.sidebarSnapshotFile = SidebarSnapshotFile.standard(launch: environment.launch)
        environment.layoutTemplatesFile = environment.sidebarSnapshotFile?.url.deletingLastPathComponent().appending(path: "layout-templates.json")
        environment.homeCachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        DebugTimings.markLaunch("main.app_environment")
        // The last quit's agent pages, terminal frames and chat composers are read and decoded off the main thread
        // from here, while AppKit starts, so each pane's first frame can use them without waiting. Where each chat
        // rests and its unsent chips are kept beside them too (AgentPaneChatStores, made with the agent tabs).
        let state = environment.sidebarSnapshotFile?.url.deletingLastPathComponent()
        // Ghostty's resources folder, CLI helper and terminfo (a few stats), before the other launch reads on the
        // files lane: every shell's env and the daemon's start await it.
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
        // cmux-next.json (made on first launch) read and merged with the managed layers on the files lane, next:
        // the launch steps that need it run when it lands, never waiting for it on main (p08-startup 025).
        let settingsRead = SettingsController.startLaunchRead(on: work, in: ledgerThenSettings)
        let launchImages = AgentPaneLaunchImages(state: state), relaunchWake = AgentPaneRelaunchWake(directory: state)
        launchImages.prefetch(on: work) { DebugTimings.markLaunch($0) }
        TerminalLaunchFrames.beside(state).prefetch(on: work) { DebugTimings.markLaunch($0) }
        environment.browserLaunchPictures = BrowserLaunchPictures(state: state, work: work)  // browser pages' (p08-startup-043)
        environment.browserLaunchPictures?.prefetch { DebugTimings.markLaunch($0) }
        environment.windowPictures = WindowPictureStore(state: state, work: work)  // the windows' (p08-startup-057)
        relaunchWake.begin(on: work)
        // The browser source registry (browser-sources.json) the import pickers and the Passwords page read:
        // in memory before them, never read on the thread that asks first (p02-threads-122).
        BrowserSourceRegistryInstall.shared.load(on: work)
        // This app's signing team, which every acpmux resolve and the Computer Use admission require: asked of
        // securityd on the system lane, so a main-thread resolve reads it from memory (p02-threads-122).
        work.post(.userVisible, mayBlock: .system) { SigningTeamInstall.process.load() }
        DebugTimings.markLaunch("main.launch_reads")
        // Tab favicons resolve their hosts on work's host-resolution slots (system lane), never on the pool;
        // video wallpapers list the windows above theirs on its system lane, never on main.
        BrowserFaviconLoader.shared.useResolver(SystemRemoteResolver(runner: work))
        BackdropVideoPlayers.shared.lanes = work
        // The launch's feature values, once, before the first feature read (the daemon connect's).
        let features = AppServices.launchFeatures(environment)
        // `debug.daemon.wire`'s counters, each schema method timed; nil in a release build unless the
        // person opted in to field data.
        let wireStats = DaemonWireStats.forBuild(fieldData: features.isEnabled(.ipcMethodLatencyFieldData),
                                                 methods: MethodTable.schema.methods.map { .init(id: $0.id.rawValue, name: $0.name) })
        // The daemon connect overlaps AppKit's start (off the main thread).
        let prestart = DaemonService.prestart(work: work, launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                                              resolvedTerminalEnvironment: environment.resolvedTerminalEnvironment(),
                                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                                              resolvesShellIntegration: environment.resolvesShellIntegration,
                                              echoesPlacementShift: SidebarMirror.isLinked, wireStats: wireStats,
                                              hangWatch: hangWatch)
        DebugTimings.markLaunch("main.prestart")
        // The front window's picture for the first frame, read and decoded on the files lane (p08-startup-058);
        // which window is front comes from the launch snapshot, read there only when a picture was saved.
        if features.isEnabled(.savedWindowPicture) {
            let snapshot = prestart.map { (session: $0.launcher.configuration.session, state: $0.launcher.configuration.stateDirectory) }
            environment.windowPictures?.prefetchFront({
                // The window `LaunchSnapshotWindow.showSaved` builds, by the same rule (WindowStateDocument.frontWindow).
                snapshot.flatMap { LaunchSnapshot.saved(session: $0.session, stateDirectory: $0.state)?.frontWindow }.map {
                    WindowPictureStore.FrontWindow(window: $0.id, profile: ($0.profile ?? .defaultProfile).rawValue)
                }
            }, mark: { DebugTimings.markLaunch($0) })
        }
        // DEV and NIGHTLY crash at an exception's throw site (cx-r3q), before NSApp exists.
        CrashOnExceptions.register()
        // Instantiate the CEF-ready subclass before anything touches NSApp.
        let app = CmuxApplication.shared
        (app as? CmuxApplication)?.refusesActivation = environment.noActivate // CMUX_NEXT_NO_ACTIVATE=1, read once above
        // The launch's order owners: the main-thread scheduler and the StartupScheduler on it, passed by init.
        // The one input tap (p04-input.md 3 (A)): the budget's pending input, control and services observe it.
        let inputTap = InputEventTap()
        // The design kit's popups, overlay hosts and tooltip subscribe to it too, before the delegate
        // and services make any: their owners in many packages make them with no tap (p04-input-013).
        WindowOverlayHost.appInputTap = inputTap
        TooltipPresenter.shared.inputTap = inputTap
        let order = LaunchOrder(fence: fence, board: mainBoard, input: inputTap) { DebugTimings.markLaunch($0) }
        // Main-actor jobs wait behind pending input (p04-input-076); installed as `debug.mainJobGate` says (AppServices.settings).
        // Classed main work (post(class:), MainNotificationObserver) waits behind the same input (p04-input-080).
        if features.isEnabled(.mainJobGate), let pending = order.mainWork.budget.pendingInput as? SessionInputPending {
            (app as? CmuxApplication)?.jobGate = MainJobGateSwitch(pending: pending, holding: order.mainWork)
        }
        DaemonLauncher.captureLoginEnvironment(after: order.startup) // at once only with nothing remembered (p08-startup-034)
        #if DEBUG || CMUX_BENCH_HOOKS
        globalJobs?.freeze(after: order.startup)
        #endif
        LaunchThreadCensus.post(on: order.startup) { LaunchMarkSink.shared.writeValue(name: $0, value: $1) } // Debug/bench: threads at the first frame (p08-startup-068)
        if let pictures = environment.windowPictures { order.startup.whenComplete { _ in pictures.dropFront() } } // decoded pictures are large
        let delegate = AppDelegate(environment: environment, daemonPrestart: prestart, wireStats: wireStats, features: features,
                                   startupTrace: startupTrace, order: order, inputTap: inputTap, settingsRead: settingsRead,
                                   launchReads: (work, launchImages, relaunchWake))
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
        // NSApplication.delegate is weak; keep the delegate alive for the run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
