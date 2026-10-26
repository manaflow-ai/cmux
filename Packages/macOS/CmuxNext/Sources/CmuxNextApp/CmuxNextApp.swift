import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextInput
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
        // Pure launch work (action catalog, symbols, displays) overlaps AppKit's start.
        LaunchWarmup.start()
        DebugTimings.markLaunch("main.warmup_started")
        // One hang watch for the process: the lanes, the daemon readers and the terminal output lanes.
        let hangWatch = TraceRuntime.shared.hangWatch
        // The launch's file reads run on these lanes, never on the main thread (p08-startup 033).
        let work = BackgroundWork(hangs: hangWatch, onRan: startupTrace?.laneJobSink)
        // Idle and best-effort lane work waits for startup complete (Chrome's BeginBestEffortFence); the order made on it lowers it.
        let fence = LaunchOrder.BestEffortFence(raisingOn: work)
        startupTrace?.start(writingOn: work) // its file is written on work's files lane, never here
        startupTrace?.whenClosed { work.stopReportingRuns() } // a closed trace costs the lanes nothing
        // Shells get the launch limit back. Path lookups only: the stores at these paths read and create on first use.
        var environment = AppEnvironment.current(openFiles: openFiles)
        environment.marksRun = true
        // Key flows start and stop at run time; CMUX_NEXT_TRACE_FLOWS only starts them at launch.
        TypingLatencyProbe.shared.startFlows(launchEnvironment: ProcessInfo.processInfo.environment)
        environment.sidebarSnapshotFile = SidebarSnapshotFile.standard(launch: environment.launch)
        environment.layoutTemplatesFile = environment.sidebarSnapshotFile?.url.deletingLastPathComponent().appending(path: "layout-templates.json")
        environment.homeCachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // The app's acpmux, resolved once on the system lane: its signature check reads this app's signature
        // (OwnCodeSignature) and hashes the binary. Main-thread users take the landed answer (QuitAgents.environment).
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
        environment.ghosttyProbe = GhosttyLaunchProbe.start(on: work)
        // The incognito workspaces a crashed run left, then the settings read, in one sequence: the launch window
        // (made after the settings read lands) knows whether it may list every workspace (p08-startup 038).
        let ledgerThenSettings = work.sequence("launch.ledger-then-settings")
        environment.incognitoLeftovers = IncognitoWorkspaceLedger.startLaunchRead(
            at: IncognitoWorkspaceLedger.standardURL(bundleIdentifier: Bundle.main.bundleIdentifier), in: ledgerThenSettings)
        // cmux-next.json (made on first launch) read and merged with the managed layers on the files lane, next:
        // the launch steps that need it run when it lands, never waiting for it on main (p08-startup 025).
        let settingsRead = SettingsController.startLaunchRead(on: work, in: ledgerThenSettings)
        let launchImages = AgentPaneLaunchImages(state: state), relaunchWake = AgentPaneRelaunchWake(directory: state)
        launchImages.prefetch(on: work) { DebugTimings.markLaunch($0) }
        TerminalLaunchFrames.beside(state).prefetch(on: work) { DebugTimings.markLaunch($0) }
        relaunchWake.begin(on: work)
        DebugTimings.markLaunch("main.launch_reads")
        // Tab favicons resolve their hosts on work's host-resolution slots (system lane), never on the pool;
        // video wallpapers list the windows above theirs on its system lane, never on main.
        BrowserFaviconLoader.shared.useResolver(SystemRemoteResolver(runner: work))
        BackdropVideoPlayers.shared.lanes = work
        let wireStats = DaemonWireStats.forBuild()  // `debug.daemon.wire`'s counters; nil in a release build
        // The daemon connect overlaps AppKit's start, all of it on the system lane: this app's signature first
        // (the launcher's install key needs the Team ID), then the launcher and its first attempt.
        let launch = environment.launch, terminalEnvironment = environment.terminalEnvironment
        let resolvedTerminalEnvironment = environment.resolvedTerminalEnvironment()
        let terminalEnvironmentProvider = environment.terminalEnvironmentProvider()
        let resolvesShellIntegration = environment.resolvesShellIntegration, echoesPlacementShift = SidebarMirror.isLinked
        let daemonStart = LaunchRead<DaemonLaunchStart>(on: work, mayBlock: .system) {
            DaemonService.launchStart(work: work, launch: launch, terminalEnvironment: terminalEnvironment,
                                      resolvedTerminalEnvironment: resolvedTerminalEnvironment,
                                      terminalEnvironmentProvider: terminalEnvironmentProvider,
                                      resolvesShellIntegration: resolvesShellIntegration, echoesPlacementShift: echoesPlacementShift,
                                      wireStats: wireStats, hangWatch: hangWatch)
        }
        DebugTimings.markLaunch("main.prestart")
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
        let order = LaunchOrder(fence: fence, input: inputTap) { DebugTimings.markLaunch($0) }
        DaemonLauncher.captureLoginEnvironment(after: order.startup) // at once only with nothing remembered (p08-startup-034)
        let delegate = AppDelegate(environment: environment, daemonStart: daemonStart, wireStats: wireStats,
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
        // NSApplication.delegate is weak; keep the delegate alive for the run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
