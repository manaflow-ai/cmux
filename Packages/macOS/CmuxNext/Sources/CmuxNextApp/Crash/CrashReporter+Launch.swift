import CmuxNextActions
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextSettings
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

/// The app process's crash reporting (cx-urd.58): the Sentry reporter and
/// the helper crash report forwarder. Starts only for the app itself
/// (`marksRun`), after the run marker installed its signal handlers.
struct AppCrashReporting: Sendable {
    let reporter: CrashReporter
    /// Nil outside the app process. With reports off it only marks reports done.
    let forwarder: SystemCrashForwarder?
    /// The app's cmux-tui owner's panic log (cx-urd.59); nil outside the app process.
    let ownerPanics: OwnerPanicForwarder?

    init(environment: AppEnvironment) {
        reporter = CrashReporter.forThisLaunch(bundleID: environment.launch.bundleID)
        guard environment.marksRun else {
            forwarder = nil
            ownerPanics = nil
            return
        }
        let sends = reporter.start()
        let forwarder = SystemCrashForwarder(
            stateFile: AppRunMarker.standardDirectory(bundleID: environment.launch.bundleID)
                .appending(path: "crash-forwarder.json"),
            bundlePath: Bundle.main.bundlePath, mainExecutable: Bundle.main.executablePath, sends: sends)
        forwarder.start()
        self.forwarder = forwarder
        let tag = environment.launch.tag
        let ownerPanics = OwnerPanicForwarder(
            log: OwnerPanicForwarder.log(stateRoot: Self.ownerStateRoot(tag: tag),
                                         session: (try? DaemonLauncher.sessionName(tag: tag)) ?? "cmux-app"),
            stateFile: AppRunMarker.standardDirectory(bundleID: environment.launch.bundleID)
                .appending(path: "owner-panic-forwarder.json"),
            sends: sends)
        ownerPanics.start()
        self.ownerPanics = ownerPanics
    }

    /// The owner's state root: the parent of its sessions directory, which
    /// is the tag's `CMUX_TUI_STATE_DIR` (DaemonLauncher) or cmux-tui's default.
    static func ownerStateRoot(tag: String?) -> URL {
        let sessions = tag.map(DaemonLauncher.tagStateDirectory(tag:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/cmux-tui/sessions", directoryHint: .isDirectory)
        return sessions.deletingLastPathComponent()
    }
}
