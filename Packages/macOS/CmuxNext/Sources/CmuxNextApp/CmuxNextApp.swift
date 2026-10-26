import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextMallocZone
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextCompat
import CmuxNextWakeups

/// Entry point called from the Xcode target's `App/main.swift`.
public struct CmuxNextApp {
    public static let shared = Self()
    public func main() {
        // First: the launch's one watchdog and the startup tag it reads, so every launch stall is listed
        // with its phase and step (Chrome makes its HangWatcher in process start-up: base/threading/hang_watcher.h).
        let watchdog = MainThreadWatchdog(startupTasks: StartupTaskTag())
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
        // Its thread is the launch's first, after the freeze; the turn it measures began at its creation.
        watchdog.start(measuringSinceCreation: true)
        // Pure launch work (action catalog, string tables) overlaps AppKit's start.
        watchdog.startupStep("main.warmup"); LaunchWarmup.start()
        DebugTimings.markLaunch("main.warmup_started")
        watchdog.startupStep("main.environment")
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
        // The daemon connect overlaps AppKit's start (off the main thread).
        watchdog.startupStep("main.daemon_prestart")
        let prestart = DaemonService.prestart(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                                              resolvesShellIntegration: environment.resolvesShellIntegration,
                                              echoesPlacementShift: SidebarMirror.isLinked)
        DebugTimings.markLaunch("main.prestart")
        #if DEBUG || CMUX_BENCH_HOOKS
        watchdog.startupStep("bench.launch_stall"); BenchLaunchStall(environment: ProcessInfo.processInfo.environment).run()
        #endif
        watchdog.startupStep("main.nsapp")
        // DEV and NIGHTLY crash at an exception's throw site (cx-r3q), before NSApp exists.
        CrashOnExceptions.register()
        // Instantiate the CEF-ready subclass before anything touches NSApp.
        let app = CmuxApplication.shared
        (app as? CmuxApplication)?.refusesActivation = ProcessInfo.processInfo.environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
        let delegate = AppDelegate(environment: environment, daemonPrestart: prestart, watchdog: watchdog)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        DebugTimings.markLaunch("main.nsapp")
        DebugTimings.markLaunch("main.run")
        watchdog.startupStep("main.run") // AppKit's own start, up to applicationDidFinishLaunching
        // NSApplication.delegate is weak; keep the delegate alive for the run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
