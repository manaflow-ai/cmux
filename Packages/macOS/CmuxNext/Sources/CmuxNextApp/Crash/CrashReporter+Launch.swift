import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCompat
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
    /// `previousRun`: the previous run's crash keys and black box for its
    /// crash event (``previousRunEvidence(marker:bundleID:)``).
    /// `hangTracking` follows feature `fatalHangReports` (p09-observability-076).
    static func forThisLaunch(
        bundleID: String?,
        hangTracking: CrashReporter.HangTracking = .sentry,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        defaults: UserDefaults = .standard,
        managed: any ManagedPreferenceReader = ManagedPreferenceLocation.defaultReader(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        previousRun: PreviousRunCrashEvidence? = nil
    ) -> CrashReporter {
        let forced = managed.read().forced[CrashReportingPolicy.disableTelemetryPolicyKey]?.boolValue == true
        return CrashReporter(policy: CrashReportingPolicy(
            bundleID: bundleID,
            shortVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            isDebugBuild: DevTools.isDebugBuild,
            telemetryOptIn: CrashReportingPolicy.telemetryOptIn(in: defaults),
            managedDisablesTelemetry: forced,
            processEnvironment: environment), hangTracking: hangTracking, previousRun: previousRun)
    }

    /// The previous run's files for its crash event (p09-observability-079): its black box and crash-key page in
    /// the app's trace folder (`TraceBlackBoxFileSteps.appDirectory`), named by its pid and checked against its
    /// process start, and its crash path's `run.crashkeys` record, which the marker's launch read took
    /// (`AppRunMarker.previousCrashKeys`). `blackbox.txt` goes only while this Mac has the hang-reports consent
    /// record (`HangReportsController.consentKey`), read when the event is sent. Nil on a first launch or without a
    /// marker; no trace file is read until a crash event asks.
    ///
    /// After an unclean exit, the event also gets the `FATAL` line Chromium wrote before it aborted the app
    /// (tag `cef.fatal`, p09-observability-084): read from the app's Chromium log only when that run ran
    /// `CefInitialize` in process and wrote it (``ChromiumFatalLog/app(previous:endedUncleanly:launched:storage:)``,
    /// with `now` this launch), then scrubbed with the event's other tags.
    static func previousRunEvidence(marker: AppRunMarker?, bundleID: String?,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    now: Date = Date()) -> PreviousRunCrashEvidence? {
        guard let marker, let run = marker.previousRun else { return nil }
        let consentKey = HangReportsController.consentKey
        let files = PreviousRunCrashEvidence.Run(
            pid: UInt32(bitPattern: run.pid), processStartUnixMicros: run.processStart,
            traceDirectory: TraceBlackBoxFileSteps.appDirectory(bundleID: bundleID, home: home).path,
            crashPathKeys: marker.previousCrashKeys)
        let cefLog = ChromiumFatalLog.app(previous: run, endedUncleanly: marker.previousExit != nil, launched: now)
        return PreviousRunCrashEvidence(
            processStartUnixMicros: run.processStart,
            read: { blackBox in Self.previousRunFiles(files, cefLog: cefLog, blackBox: blackBox) },
            hangReportsOptIn: { UserDefaults.standard.object(forKey: consentKey) is Date })
    }

    /// The previous run's files (``PreviousRunCrashEvidence/read(_:blackBox:)``) and, from `cefLog`, its
    /// `cef.fatal` tag. Blocking file work, on the queue Sentry sends from.
    nonisolated static func previousRunFiles(_ run: PreviousRunCrashEvidence.Run, cefLog: ChromiumFatalLog?,
                                             blackBox: Bool) -> PreviousRunCrashEvidence.Files {
        var files = PreviousRunCrashEvidence.read(run, blackBox: blackBox)
        if let line = cefLog?.read() { files.tags[CEFFatalLine.tag] = line.tagValue }
        return files
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
    /// The helper crash reports, the app's cmux-tui owner's panic log (cx-urd.59) and its acpmux
    /// daemon's (`$ACPMUX_HOME/panics.jsonl`); nil outside the app process. With reports off they
    /// only mark reports done.
    let forwarders: CrashForwarders?

    /// - Parameters:
    ///   - features: The features the app runs with, put on the Sentry scope right after it starts
    ///     (`DebugSettingsService.start` keeps them current as live Debug toggles change, `CrashReporter.followFeatures`).
    ///   - afterStartup: How Sentry starts and when its paused part resumes (feature `sentryHandlersFirst`).
    ///   - hangSinks: The main-thread watchdog's hang sinks, set before Sentry starts; they decide whether Sentry's
    ///     app-hang tracker runs (``WatchdogHangSinks/hangTracking``). Nil (tests, no watchdog) keeps the tracker.
    ///   - forwardersAfterStartup: The launch's scheduler with feature `crashForwardersAfterStartup`: the
    ///     forwarders run in its afterStartup lane post (``CrashForwarders/post(on:)``). Nil: they start now.
    ///   - runMarker: The app's run marker: the previous run's crash event, sent after the start, gets that run's
    ///     crash keys and black box (p09-observability-079).
    init(environment: AppEnvironment, features: CrashFeatureScope? = nil,
         afterStartup: AfterStartup = AfterStartup(handlersFirst: false, startup: nil),
         hangSinks: WatchdogHangSinks? = nil, forwardersAfterStartup: StartupScheduler? = nil, runMarker: AppRunMarker? = nil) {
        let previousRun = CrashReporter.previousRunEvidence(marker: runMarker, bundleID: environment.launch.bundleID)
        reporter = CrashReporter.forThisLaunch(bundleID: environment.launch.bundleID, hangTracking: hangSinks?.hangTracking ?? .sentry,
                                               previousRun: previousRun)
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        guard environment.marksRun else {
            // No Sentry in this process: the running build still decides when a notFatalUntil site traps.
            InvariantSink.install(reporter: reporter, bundleVersion: bundleVersion)
            forwarders = nil
            return
        }
        // Before the start: with Sentry's tracker off, the watchdog reports every hang from the start on (p09-observability-076).
        hangSinks?.install(reporter: reporter)
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
        let ownerPanics = OwnerPanicForwarder(
            log: OwnerPanicForwarder.log(stateRoot: Self.ownerStateRoot(stateDirectory: environment.daemonStateDirectory),
                                         session: environment.daemonSession),
            stateFile: stateDirectory.appending(path: "owner-panic-forwarder.json"),
            sends: sends)
        // A panic in a daemon request task ends only that task: before this log, the
        // 2026-10-14 sort panic reached only daemon.log.
        let forwarders = CrashForwarders(system: system, ownerPanics: ownerPanics) { [build = environment.build] in
            Self.acpmuxHome(build: build).map { home in
                OwnerPanicForwarder(log: RustPanicSource.acpmuxLog(acpmuxHome: home),
                                    stateFile: stateDirectory.appending(path: "acpmux-panic-forwarder.json"),
                                    sends: sends, source: .acpmux)
            }
        }
        if let forwardersAfterStartup { forwarders.post(on: forwardersAfterStartup) } else { forwarders.start() }
        self.forwarders = forwarders
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

    /// The home of the acpmux daemon this app starts (the same rule as its agent panes). Reads the file system.
    nonisolated static func acpmuxHome(build: BuildIdentity?) -> URL? {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        return AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: bin,
                                         environment: ProcessInfo.processInfo.environment)?.home
    }

    /// The owner's state root: the parent of its sessions directory, which
    /// is the build's `CMUX_TUI_STATE_DIR` (DaemonLauncher.appNames) or cmux-tui's default.
    static func ownerStateRoot(stateDirectory: URL?) -> URL {
        let sessions = stateDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/cmux-tui/sessions", directoryHint: .isDirectory)
        return sessions.deletingLastPathComponent()
    }
}
