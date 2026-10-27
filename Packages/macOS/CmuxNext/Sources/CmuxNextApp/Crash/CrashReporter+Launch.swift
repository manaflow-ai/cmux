import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHangReports
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
/// the process's invariant sink (p10-stability-099) and the crash report and
/// panic log forwarders. Starts only for the app itself
/// (`marksRun`), after the run marker installed its signal handlers.
///
/// With feature `sentryHandlersFirst` (p08-startup-032) Sentry starts with
/// ``CrashReporter/StartProfile/handlersFirst`` and its app-hang reports resume
/// in one afterStartup post (``AfterStartup``). With feature
/// `crashForwardersAfterStartup` (p08-startup-078) the forwarders' first pass
/// (the DiagnosticReports listing, the panic logs) and their watches are one
/// afterStartup best-effort files-lane post, behind the best-effort fence; the
/// handlers and the LayoutPassGuard install at once either way. Chrome posts non-critical
/// startup work through `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc). The `crash.sentry_start` and
/// `crash.sentry_started` launch marks bound the start
/// (`LaunchSignposts.Interval.sentryStart`).
struct AppCrashReporting: Sendable {
    let reporter: CrashReporter
    /// The helper crash reports and every shipped Rust process's panic and hang logs (cx-urd.59,
    /// p09-observability-075: ``RustDiagnosticsLog/all(_:)``), the acpmux daemon's among them; nil outside the
    /// app process. With reports off they only mark reports done.
    let forwarders: CrashForwarders?

    /// - Parameters:
    ///   - features: The features the app runs with, put on the Sentry scope right after it starts
    ///     (`DebugSettingsService.start` keeps them current as live Debug toggles change, `CrashReporter.followFeatures`).
    ///   - afterStartup: How Sentry starts and when its paused part resumes (feature `sentryHandlersFirst`).
    ///   - forwardersAfterStartup: The launch's scheduler with feature `crashForwardersAfterStartup`: the
    ///     forwarders run in its afterStartup lane post (``CrashForwarders/post(on:)``). Nil: they start now.
    init(environment: AppEnvironment, features: CrashFeatureScope? = nil,
         afterStartup: AfterStartup = AfterStartup(handlersFirst: false, startup: nil),
         forwardersAfterStartup: StartupScheduler? = nil) {
        reporter = CrashReporter.forThisLaunch(bundleID: environment.launch.bundleID)
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        guard environment.marksRun else {
            // No Sentry in this process: the running build still decides when a notFatalUntil site traps.
            InvariantSink.install(reporter: reporter, bundleVersion: bundleVersion)
            forwarders = nil
            return
        }
        DebugTimings.markLaunch("crash.sentry_start")
        let sends = reporter.start(profile: afterStartup.profile)
        DebugTimings.markLaunch("crash.sentry_started")
        // After the start, so the invariant sink sends only when Sentry runs (p10-stability-099).
        InvariantSink.install(reporter: reporter, bundleVersion: bundleVersion)
        if let features { reporter.setFeatures(features) }
        afterStartup.schedule { [reporter = self.reporter] in reporter.resumeAfterStartup() }
        let stateDirectory = AppRunMarker.standardDirectory(bundleID: environment.launch.bundleID)
        let system = SystemCrashForwarder(
            stateFile: stateDirectory.appending(path: "crash-forwarder.json"),
            bundlePath: Bundle.main.bundlePath, mainExecutable: Bundle.main.executablePath, sends: sends)
        // Every shipped Rust process's panic and hang logs but acpmux's, which the forwarders' first pass adds
        // because finding acpmux reads the file system. The owner's and acpmux's offsets from before the log list
        // carry over.
        let sessions = Self.ownerSessionsDirectory(stateDirectory: environment.daemonStateDirectory)
        let roots = RustDiagnosticsLog.Roots.app(sessionsDirectory: sessions, session: environment.daemonSession, acpmuxHome: nil,
                                                 bundleID: environment.launch.bundleID)
        let rustDiagnostics = RustDiagnosticsForwarder(
            logs: RustDiagnosticsLog.all(roots), stateFile: stateDirectory.appending(path: "rust-diagnostics-forwarder.json"),
            legacyStates: [OwnerPanicForwarder.log(stateRoot: roots.stateRoot, session: environment.daemonSession):
                           stateDirectory.appending(path: "owner-panic-forwarder.json")],
            sends: sends)
        // A panic in an acpmux request task ends only that task: before its log, the 2026-10-14 sort panic
        // reached only daemon.log.
        let forwarders = CrashForwarders(system: system, ownerPanics: rustDiagnostics) { [build = environment.build] in
            Self.acpmuxHome(build: build).map { home in
                RustDiagnosticsForwarder(
                    logs: RustDiagnosticsLog.acpmux(home: home),
                    stateFile: stateDirectory.appending(path: "acpmux-diagnostics-forwarder.json"),
                    legacyStates: [RustPanicSource.acpmuxLog(acpmuxHome: home): stateDirectory.appending(path: "acpmux-panic-forwarder.json")],
                    sends: sends)
            }
        }
        if let forwardersAfterStartup { forwarders.post(on: forwardersAfterStartup) } else { forwarders.start() }
        self.forwarders = forwarders
        Self.installLayoutPassGuard(reporter: reporter)
    }

    /// Each Rust hang line sent is also a hang-report entry, the lines read before this call too (the collector exists
    /// after crash reporting starts; its own opt-in decides whether it keeps them).
    func attachHangReports(_ collector: HangReportCollector) {
        forwarders?.setHangEntries { record, _ in
            let frames = record.frames.map { frame in
                let image = record.image(of: frame)
                return HangReportCollector.ForeignFrame(image: image?.name, uuid: image?.uuid, offset: image == nil ? nil : frame.offset)
            }
            collector.noteProcessHang(durationMs: Int(clamping: record.overdueMs), frames: frames,
                                      thread: HangSample.WatchedThread(name: record.thread, kind: record.threadKind))
        }
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

    /// The home of the acpmux daemon this app starts (the same rule as its agent panes). Reads the file system.
    nonisolated static func acpmuxHome(build: BuildIdentity?) -> URL? {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        return AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: bin,
                                         environment: ProcessInfo.processInfo.environment)?.home
    }

    /// The owner's sessions directory: the build's `CMUX_TUI_STATE_DIR` (DaemonLauncher.appNames) or cmux-tui's
    /// default. Its parent is the owner's state root.
    static func ownerSessionsDirectory(stateDirectory: URL?) -> URL {
        stateDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/cmux-tui/sessions", directoryHint: .isDirectory)
    }
}
