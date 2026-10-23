import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextMallocZone
import CmuxNextTerminal
import CmuxNextCompat

/// Entry point called from the Xcode target's `App/main.swift`.
public struct CmuxNextApp {
    public static let shared = Self()
    public func main() {
        DebugTimings.markLaunch("main_start")
        // First, while the process has one thread: install the delegating
        // default malloc zone Chromium expects (Chromium's
        // EarlyMallocZoneRegistration). The Chromium framework is mapped
        // later on a background thread; its PartitionAlloc constructor then
        // swaps zones without a moment where no zone owns system memory.
        // Without this, a free() on another thread in that moment crashed
        // with "No zone found" (browser-isolation.md, allocator zone race).
        _ = cmux_early_malloc_zone_registration()
        // Before any socket or pipe exists (ChildSignalDefaults).
        ChildSignalDefaults.installAppSignalPolicy()
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
        var environment = AppEnvironment.current()
        environment.marksRun = true
        let sidebarSnapshotFile = SidebarSnapshotFile.standard(launch: environment.launch)
        environment.sidebarSnapshotFile = sidebarSnapshotFile
        // What the first window draws (saved sidebars, last terminal frames and agent page images)
        // is read and decoded off the main thread while AppKit starts (#17587).
        environment.launchFiles = LaunchFiles(sidebarFile: sidebarSnapshotFile)
        environment.layoutTemplatesFile = environment.sidebarSnapshotFile?.url.deletingLastPathComponent().appending(path: "layout-templates.json")
        // Where each agent chat rests, beside the snapshot, so a relaunch reopens it there (cx-6bgzj).
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
        // Each chat's unsent chips, beside it, so reopening or restoring a chat brings them back.
        AgentPaneDraftAttachments.shared = AgentPaneDraftAttachments(directory: environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
        // The daemon connect overlaps AppKit's start (off the main thread).
        let prestart = DaemonService.prestart(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                                              terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                                              resolvesShellIntegration: environment.resolvesShellIntegration)
        DebugTimings.markLaunch("main.prestart")
        // DEV and NIGHTLY crash at an exception's throw site (cx-r3q), before NSApp exists.
        CrashOnExceptions.register()
        // Instantiate the CEF-ready subclass before anything touches NSApp.
        let app = CmuxApplication.shared
        (app as? CmuxApplication)?.refusesActivation = ProcessInfo.processInfo.environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
        let delegate = AppDelegate(environment: environment, daemonPrestart: prestart)
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
