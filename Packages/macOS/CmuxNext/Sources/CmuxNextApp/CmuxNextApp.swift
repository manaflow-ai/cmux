import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextMacScreen
import CmuxNextMallocZone
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextCompat
import CmuxNextUpdater
import CmuxNextWakeups

/// Entry point called from the stub `App/main.swift`: CmuxNextApp.framework's only export (Package.swift, CMUX-629).
@_cdecl("cmux_next_app_main") public func cmuxNextAppMain() { CmuxNextApp().main() }
public struct CmuxNextApp {
    public func main() {
        if StagedUpdatePrewarm.isPrewarm(CommandLine.arguments) { _exit(0) }; DebugTimings.markLaunch("main_start") // a pre-warm needs only exec and dyld; `_exit` skips atexit handlers and static destructors
        if StagedUpdatePrewarm.isChromiumPrewarm(CommandLine.arguments) { _ = cmux_early_malloc_zone_registration(); _exit(CEFStagedPrewarm().run(application: CmuxApplication.shared).rawValue) }; MacScreenStreamChild(arguments: CommandLine.arguments)?.run() // _exit: no static destructors under Chromium's threads; the Screen Sharing helper's child (the iPhone viewer's screen host) runs and exits, no app starts
        if case let epoch = cmux_next_first_initializer_epoch(), epoch > 0 { DebugTimings.markLaunch("premain.first_initializer", at: Date(timeIntervalSince1970: epoch)) } // process start to here: exec and dyld; to main_start: static initializers
        announceBenchHooksBuild()
        ClassicFolderItemsMove.moveConfigItems(paths: .current); ScrollerStylePin().apply(to: .standard); FontSmoothingSetting.applyBeforeLaunch() // concurrency-allow: a few lstats, and once the renames of NEXT's files out of classic's config folder, before anything reads the settings file; defaults AppKit reads once as it starts: overlay scrollers, any mouse or setting; appearance.fontSmoothing
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
        DebugTimings.markLaunch("main.setup_done") // main_start to here: malloc zone, signals, environment, SingleInstanceGuard
        // Pure launch work (action catalog, string tables) overlaps AppKit's start.
        LaunchWarmup.start(); AcpmuxEnvironment.startBuildHomeAdoption() // the old homes' adoption, before anything awaits it
        DebugTimings.markLaunch("main.warmup_started")
        var environment = AppEnvironment.current(openFiles: openFiles) // shells get the launch limit back
        environment.marksRun = true
        // An unclicked update relaunch comes back behind the user's app: read (and cleared) before any activation; agent launches never activate.
        if !environment.noActivate {
            environment.relaunchBehind = UpdateRelaunchFocus.consume(
                build: UpdateBuildIdentity.main().build,
                reopenedBehind: ProcessInfo.processInfo.arguments.contains(UpdateRelaunchFocus.reopenArgument))
        }; DebugTimings.markLaunch("main.environment")
        // concurrency-allow: one lstat, and once one rename of the folder older builds kept in classic's cmux, before anything reads it
        StateFolderMove().run(build: environment.launch.build)
        environment.sidebarSnapshotFile = SidebarSnapshotFile.standard(launch: environment.launch)
        environment.layoutTemplatesFile = environment.sidebarSnapshotFile?.url.deletingLastPathComponent().appending(path: "layout-templates.json")
        // `~/Library/Caches`, a DEV build's own caches folder (BuildStatePaths): Home's blob cache is not keyed by owner.
        environment.homeCachesDirectory = BuildStatePaths.current.homeCachesRoot
        // Each chat's unsent chips, beside it, so reopening or restoring a chat brings them back.
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
        // The last quit's agent pages, terminal frames and chat composers are read and decoded off the main thread
        // from here, while AppKit starts, so each pane's first frame can use them without waiting.
        DebugTimings.markLaunch("main.state_folder"); let state = environment.sidebarSnapshotFile?.url.deletingLastPathComponent(), work = BackgroundWork()
        let launchSnapshot = LaunchSnapshot.readAtLaunch(work: work, build: environment.launch.build) // first on the lane: the launch window is drawn from it
        let launchImages = AgentPaneLaunchImages(state: state), relaunchWake = AgentPaneRelaunchWake(directory: state), chromium = CEFLaunchPrefetch()
        launchImages.prefetch(on: work) { DebugTimings.markLaunch($0) }; chromium.start(on: work, when: launchImages.savedPagesExist) // a restored Chromium page's framework
        TerminalLaunchFrames.beside(state).prefetch(on: work, mark: { DebugTimings.markLaunch($0) }, markAt: { DebugTimings.markLaunch($0, at: $1) })
        relaunchWake.begin(on: work)
        // The bundled CLI's Cloud environment read, off the main thread while AppKit starts; the daemon starts after it.
        let cloudEnvironment = CloudEnvironmentBootstrap.startAtLaunch(work: work)
        DebugTimings.markLaunch("main.reads_started") // DEV and NIGHTLY crash at an exception's throw site (cx-r3q), before NSApp exists.
        CrashOnExceptions.register(); DebugTimings.markLaunch("main.crash_handlers")
        // Instantiate the CEF-ready subclass before anything touches NSApp.
        let app = CmuxApplication.shared; DebugTimings.markLaunch("main.nsapp_made")
        (app as? CmuxApplication)?.refusesActivation = ProcessInfo.processInfo.environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
            || environment.relaunchBehind != nil
        let delegate = AppDelegate(environment: environment, // stage 0 (LaunchShell): its plan and image decode while AppKit starts; none for agent, test and relaunch-behind launches
                                   launchReads: (work, launchImages, relaunchWake, chromium, LaunchShell.atLaunch(bundleID: environment.noActivate || environment.testWindow != nil || environment.relaunchBehind != nil ? nil : environment.launch.bundleID, session: environment.daemonSession) { DebugTimings.markLaunch($0) }), cloudEnvironment: cloudEnvironment, launchSnapshot: launchSnapshot)
        DebugTimings.markLaunch("main.delegate_made"); app.delegate = delegate; app.setActivationPolicy(.regular)
        DebugTimings.markLaunch("main.nsapp"); DebugTimings.markLaunch("main.run")
        // NSApplication.delegate is weak; keep the delegate alive for the run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
