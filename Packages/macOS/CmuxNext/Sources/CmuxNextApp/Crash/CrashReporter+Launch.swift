import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

extension CrashReporter {
    /// This launch's crash reporter (cx-urd.58): the bundle's channel and
    /// version, the user's `sendAnonymousTelemetry` choice in the app's own
    /// defaults (shared with the main app's same-channel bundle), and a
    /// forced `DisableTelemetry` from the managed domains, all read once.
    static func forThisLaunch(
        bundleID: String?,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        defaults: UserDefaults = .standard,
        managed: any ManagedPreferenceReader = ManagedPreferenceLocation.defaultReader(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CrashReporter {
        let forced = managed.read().forced[CrashReportingPolicy.disableTelemetryPolicyKey]?.boolValue == true
        return CrashReporter(policy: CrashReportingPolicy(
            bundleID: bundleID,
            shortVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            isDebugBuild: DevTools.isDebugBuild,
            telemetryOptIn: CrashReportingPolicy.telemetryOptIn(in: defaults),
            managedDisablesTelemetry: forced,
            processEnvironment: environment))
    }
}

/// The app process's crash reporting (cx-urd.58): the Sentry reporter,
/// the process's invariant sink (p10-stability-099) and the helper crash
/// report forwarder. Starts only for the app itself
/// (`marksRun`), after the run marker installed its signal handlers.
///
/// With feature `sentryHandlersFirst` (p08-startup-032) Sentry starts with
/// ``CrashReporter/StartProfile/handlersFirst`` and its app-hang reports resume
/// in one afterStartup post (``AfterStartup``), as Chrome posts non-critical
/// startup work through `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc). The `crash.sentry_start` and
/// `crash.sentry_started` launch marks bound the start
/// (`LaunchSignposts.Interval.sentryStart`).
struct AppCrashReporting: Sendable {
    let reporter: CrashReporter
    /// Nil outside the app process. With reports off it only marks reports done.
    let forwarder: SystemCrashForwarder?
    /// The Rust logs sent to Sentry, empty outside the app process: the cmux-tui owner's panic
    /// log (cx-urd.59) and hang log, its terminal holder's panic log, and with an acpmux, the panic
    /// log of its daemon and agent hosts and the daemon's hang log
    /// (`$ACPMUX_HOME/panics.jsonl`, `hangs.jsonl`; p10-stability-150).
    let rustLogs: [OwnerPanicForwarder]

    /// - Parameters:
    ///   - features: The features the app runs with, put on the Sentry scope right after it starts
    ///     (`DebugSettingsService.start` keeps them current as live Debug toggles change, `CrashReporter.followFeatures`).
    ///   - afterStartup: How Sentry starts and when its paused part resumes (feature `sentryHandlersFirst`).
    init(environment: AppEnvironment, features: CrashFeatureScope? = nil,
         afterStartup: AfterStartup = AfterStartup(handlersFirst: false, startup: nil)) {
        reporter = CrashReporter.forThisLaunch(bundleID: environment.launch.bundleID)
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        guard environment.marksRun else {
            // No Sentry in this process: the running build still decides when a notFatalUntil site traps.
            InvariantSink.install(reporter: reporter, bundleVersion: bundleVersion)
            forwarder = nil
            rustLogs = []
            return
        }
        DebugTimings.markLaunch("crash.sentry_start")
        let sends = reporter.start(profile: afterStartup.profile)
        DebugTimings.markLaunch("crash.sentry_started")
        // After the start, so the invariant sink sends only when Sentry runs (p10-stability-099).
        InvariantSink.install(reporter: reporter, bundleVersion: bundleVersion)
        if let features { reporter.setFeatures(features) }
        afterStartup.schedule { [reporter = self.reporter] in reporter.resumeAfterStartup() }
        let forwarder = SystemCrashForwarder(
            stateFile: AppRunMarker.standardDirectory(bundleID: environment.launch.bundleID)
                .appending(path: "crash-forwarder.json"),
            bundlePath: Bundle.main.bundlePath, mainExecutable: Bundle.main.executablePath, sends: sends)
        forwarder.start()
        self.forwarder = forwarder
        let stateDirectory = AppRunMarker.standardDirectory(bundleID: environment.launch.bundleID)
        let sessions = Self.ownerSessionsDirectory(stateDirectory: environment.daemonStateDirectory)
        let stateRoot = sessions.deletingLastPathComponent()
        let session = environment.daemonSession
        var logs: [(log: URL, stateFile: String, source: RustPanicSource)] = [
            (OwnerPanicForwarder.log(stateRoot: stateRoot, session: session), "owner-panic-forwarder.json", .owner),
            (OwnerPanicForwarder.hangLog(stateRoot: stateRoot, session: session), "owner-hang-forwarder.json",
             .ownerHangs),
            // A holder panic can end every terminal it keeps; it unwinds, so no system crash report has it.
            (RustPanicSource.holderLog(sessionsDirectory: sessions, session: session), "holder-panic-forwarder.json",
             .holder),
        ]
        // A panic in a daemon request task ends only that task: before this log, the
        // 2026-10-14 sort panic reached only daemon.log.
        if let home = Self.acpmuxHome(environment: environment) {
            logs.append((RustPanicSource.acpmuxLog(acpmuxHome: home), "acpmux-panic-forwarder.json", .acpmux))
            logs.append((RustPanicSource.acpmuxHangLog(acpmuxHome: home), "acpmux-hang-forwarder.json", .acpmuxHangs))
        }
        rustLogs = logs.map { entry -> OwnerPanicForwarder in
            let forwarder = OwnerPanicForwarder(log: entry.log, stateFile: stateDirectory.appending(path: entry.stateFile),
                                                sends: sends, source: entry.source)
            forwarder.start()
            return forwarder
        }
        Self.installLayoutPassGuard(reporter: reporter)
    }

    /// How Sentry starts and when the part it pauses resumes. Off (the standard start): nothing is paused,
    /// so nothing waits. On (feature `sentryHandlersFirst`): app-hang reports are paused at start and resume
    /// in one afterStartup main post of the launch's scheduler, or at once without a scheduler (tests).
    struct AfterStartup {
        /// The post's name in the startup log.
        static let taskName: StaticString = "CrashReporting.afterStartup"
        let handlersFirst: Bool
        let startup: StartupScheduler?

        /// The start profile that matches ``schedule(_:)``.
        var profile: CrashReporter.StartProfile { handlersFirst ? .handlersFirst : .standard }

        /// Runs `resume` once startup completes, with ``profile`` `.handlersFirst`; never with `.standard`.
        func schedule(_ resume: @escaping @MainActor @Sendable () -> Void) {
            guard handlersFirst else { return }
            guard let startup else { return resume() }
            startup.post(.afterStartup, Self.taskName, on: .main, resume)
        }
    }

    /// A layout feedback loop (one view laid out more than
    /// its window's LayoutPassGuard limit in one window layout) is reported, with
    /// the view's class, before AppKit throws its layout-pass exception.
    static func installLayoutPassGuard(reporter: CrashReporter) {
        let guardian = LayoutPassGuard.shared
        guardian.onLoop = { report in
            reporter.captureNonFatal(
                "layout loop: \(report.viewClass) laid out \(report.passes) times in one window layout",
                type: "LayoutLoop", fingerprint: ["layout-loop", report.viewClass],
                tags: ["layout_loop_view": report.viewClass, "layout_loop_window": report.windowClass ?? "none",
                       "layout_loop_limit": String(report.limit)],
                extra: ["ancestry": report.ancestry.joined(separator: " < ")])
        }
        guardian.install()
    }

    /// The home of the acpmux daemon this app starts (the same rule as its agent panes).
    static func acpmuxHome(environment: AppEnvironment) -> URL? {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        return AcpmuxEnvironment.resolve(build: environment.build, bundledBinDirectory: bin,
                                         environment: ProcessInfo.processInfo.environment)?.home
    }

    /// The owner's sessions directory: the build's `CMUX_TUI_STATE_DIR` (DaemonLauncher.appNames)
    /// or cmux-tui's default. Its parent is the state root of the owner's panic and hang logs.
    static func ownerSessionsDirectory(stateDirectory: URL?) -> URL {
        stateDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/cmux-tui/sessions", directoryHint: .isDirectory)
    }
}
