import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextMallocZone
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextCompat
import CmuxNextUpdater
import CmuxNextWakeups

/// Entry point called from the Xcode target's `App/main.swift`.
public struct CmuxNextApp {
    public static let shared = Self()
    public func main() {
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
        // A second copy of this bundle for this user hands off to the running one and exits, before it
        // reads the relaunch-focus record or a session and before CEF (SingleInstanceGuard).
        if case .handOff(let activates) = SingleInstanceGuard.current.resolve() {
            SingleInstanceGuard.handOff(activates: activates)
        }
        // Pure launch work (action catalog, string tables) overlaps AppKit's start.
        LaunchWarmup.start()
        DebugTimings.markLaunch("main.warmup_started")
        var environment = AppEnvironment.current(openFiles: openFiles) // shells get the launch limit back
        environment.marksRun = true
        // A relaunch into an update nobody clicked comes back behind the user's app; read (and
        // cleared) before anything can activate the app. An agent launch never activates anyway.
        if !environment.noActivate {
            environment.relaunchBehind = UpdateRelaunchFocus.consume(
                build: UpdateBuildIdentity.main().build,
                reopenedBehind: ProcessInfo.processInfo.arguments.contains(UpdateRelaunchFocus.reopenArgument))
        }
        environment.sidebarSnapshotFile = SidebarSnapshotFile.standard(launch: environment.launch)
        environment.layoutTemplatesFile = environment.sidebarSnapshotFile?.url.deletingLastPathComponent().appending(path: "layout-templates.json")
        environment.homeCachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Each chat's unsent chips, beside it, so reopening or restoring a chat brings them back.
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
        // The last quit's agent pages, terminal frames and chat composers are read and decoded off the main thread
        // from here, while AppKit starts, so each pane's first frame can use them without waiting.
        let state = environment.sidebarSnapshotFile?.url.deletingLastPathComponent(), work = BackgroundWork()
        let launchImages = AgentPaneLaunchImages(state: state), relaunchWake = AgentPaneRelaunchWake(directory: state)
        launchImages.prefetch(on: work) { DebugTimings.markLaunch($0) }
        TerminalLaunchFrames.beside(state).prefetch(on: work, mark: { DebugTimings.markLaunch($0) },
                                                    markAt: { DebugTimings.markLaunch($0, at: $1) })
        relaunchWake.begin(on: work)
        // The daemon connect overlaps AppKit's start (off the main thread).
        let prestart = DaemonService.prestart(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                                              resolvesShellIntegration: environment.resolvesShellIntegration,
                                              echoesPlacementShift: SidebarMirror.isLinked)
        DebugTimings.markLaunch("main.prestart")
        // DEV and NIGHTLY crash at an exception's throw site (cx-r3q), before NSApp exists.
        CrashOnExceptions.register()
        // Instantiate the CEF-ready subclass before anything touches NSApp.
        let app = CmuxApplication.shared
        (app as? CmuxApplication)?.refusesActivation = ProcessInfo.processInfo.environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
            || environment.relaunchBehind != nil
        let delegate = AppDelegate(environment: environment, daemonPrestart: prestart,
                                   launchReads: (work, launchImages, relaunchWake))
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
