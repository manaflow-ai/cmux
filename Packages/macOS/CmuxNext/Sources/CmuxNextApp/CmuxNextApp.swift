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
        // Pure launch work (action catalog, string tables) overlaps AppKit's start.
        LaunchWarmup.start()
        DebugTimings.markLaunch("main.warmup_started")
        var environment = AppEnvironment.current(openFiles: openFiles) // shells get the launch limit back
        environment.marksRun = true
        environment.sidebarSnapshotFile = SidebarSnapshotFile.standard(launch: environment.launch)
        environment.layoutTemplatesFile = environment.sidebarSnapshotFile?.url.deletingLastPathComponent().appending(path: "layout-templates.json")
        environment.homeCachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Where each agent chat rests, beside the snapshot, so a relaunch reopens it there (cx-6bgzj).
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
        // Each chat's unsent chips, beside it, so reopening or restoring a chat brings them back.
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
        // The last quit's agent pages, terminal frames and chat composers are read and decoded off the main thread
        // from here, while AppKit starts, so each pane's first frame can use them without waiting.
        // One hang watch for the process: the lanes, the daemon readers and the terminal output lanes.
        let hangWatch = TraceRuntime.shared.hangWatch
        let state = environment.sidebarSnapshotFile?.url.deletingLastPathComponent()
        let work = BackgroundWork(hangs: hangWatch, onRan: startupTrace?.laneJobSink)
        // Idle and best-effort lane work waits for startup complete (Chrome's BeginBestEffortFence); the order made on it lowers it.
        let fence = LaunchOrder.BestEffortFence(raisingOn: work)
        startupTrace?.start(writingOn: work) // its file is written on work's files lane, never here
        startupTrace?.whenClosed { work.stopReportingRuns() } // a closed trace costs the lanes nothing
        let launchImages = AgentPaneLaunchImages(state: state), relaunchWake = AgentPaneRelaunchWake(directory: state)
        launchImages.prefetch(on: work) { DebugTimings.markLaunch($0) }
        TerminalLaunchFrames.beside(state).prefetch(on: work) { DebugTimings.markLaunch($0) }
        relaunchWake.begin(on: work)
        // Tab favicons resolve their hosts on work's host-resolution slots (system lane), never on the pool;
        // video wallpapers list the windows above theirs on its system lane, never on main.
        BrowserFaviconLoader.shared.useResolver(SystemRemoteResolver(runner: work))
        BackdropVideoPlayers.shared.lanes = work
        let wireStats = DaemonWireStats.forBuild()  // `debug.daemon.wire`'s counters; nil in a release build
        // The daemon connect overlaps AppKit's start (off the main thread).
        let prestart = DaemonService.prestart(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                                              resolvesShellIntegration: environment.resolvesShellIntegration,
                                              echoesPlacementShift: SidebarMirror.isLinked, wireStats: wireStats,
                                              hangWatch: hangWatch)
        DebugTimings.markLaunch("main.prestart")
        // DEV and NIGHTLY crash at an exception's throw site (cx-r3q), before NSApp exists.
        CrashOnExceptions.register()
        // Instantiate the CEF-ready subclass before anything touches NSApp.
        let app = CmuxApplication.shared
        (app as? CmuxApplication)?.refusesActivation = ProcessInfo.processInfo.environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
        // The launch's order owners: the main-thread scheduler and the StartupScheduler on it, passed by init.
        // The one input tap (p04-input.md 3 (A)): the budget's pending input, control and services observe it.
        let inputTap = InputEventTap()
        let order = LaunchOrder(fence: fence, input: inputTap) { DebugTimings.markLaunch($0) }
        let delegate = AppDelegate(environment: environment, daemonPrestart: prestart, wireStats: wireStats,
                                   startupTrace: startupTrace, order: order, inputTap: inputTap,
                                   launchReads: (work, launchImages, relaunchWake))
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
