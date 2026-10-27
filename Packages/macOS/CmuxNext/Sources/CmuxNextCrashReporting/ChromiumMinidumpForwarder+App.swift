public import Foundation

extension ChromiumMinidumpForwarder {
    /// The app's forwarder: dumps go to Sentry's minidump endpoint of ``CrashReporter/dsn`` only from NIGHTLY (or a
    /// DEV build with `devOptInKey` set to `1`, an end-to-end check), with crash reports on (`sends`), outside test
    /// processes, and while this Mac's hang report consent record (`consentKey` in the app's defaults, the record
    /// hang reports send with) exists, read at each pass. Otherwise every dump is deleted unsent.
    /// - Parameters:
    ///   - policy: This launch's crash reporting policy.
    ///   - sends: Whether Sentry runs this launch.
    ///   - stateFile: Where the sent pids are kept.
    ///   - consentKey: The `UserDefaults` key of the consent record (a `Date`).
    ///   - devOptInKey: The environment switch that lets a DEV build send.
    ///   - database: Crashpad's database, or nil when the build runs no Crashpad (read on the forwarder's queue).
    ///   - environment: The process environment.
    public static func forThisApp(policy: CrashReportingPolicy, sends: Bool, stateFile: URL, consentKey: String,
                                  devOptInKey: String, database: @escaping @Sendable () -> URL?,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> ChromiumMinidumpForwarder {
        let channelAllows = policy.channel == .nightly || (policy.channel == .dev && environment[devOptInKey] == "1")
        let allowed = sends && channelAllows && !CrashReportingPolicy.isTestProcess(environment)
        return ChromiumMinidumpForwarder(
            database: database, stateFile: stateFile, mainExecutableName: Bundle.main.executableURL?.lastPathComponent,
            // UserDefaults is thread-safe; the record is read in the app's own domain, as hang reports read it.
            mayForward: { allowed && UserDefaults.standard.object(forKey: consentKey) is Date }, labels: Labels(policy: policy),
            uploader: URLSessionMinidumpUploader(dsn: CrashReporter.dsn))
    }
}
