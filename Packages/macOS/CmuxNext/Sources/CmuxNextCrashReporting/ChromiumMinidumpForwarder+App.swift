public import Foundation

extension ChromiumMinidumpForwarder {
    /// The app's forwarder. With crash reports off (`sends` false) or in a test process, every dump is deleted unsent.
    /// Otherwise each crash goes to Sentry: as the redacted dump, to the minidump endpoint of ``CrashReporter/dsn``,
    /// on a build that may send hang reports (NIGHTLY, or DEV with `devOptInKey` set to `1`, an end-to-end check)
    /// while `consent` says hang reports are on; as a crash summary otherwise (``Mode/summary``). Until the hang
    /// report controller first applies its setting this launch, dumps wait (``Mode/wait``).
    /// - Parameters:
    ///   - policy: This launch's crash reporting policy.
    ///   - sends: Whether Sentry runs this launch.
    ///   - stateFile: Where the sent pids are kept.
    ///   - consent: The hang report controller's decision (``Consent``).
    ///   - devOptInKey: The environment switch that lets a DEV build send hang reports.
    ///   - database: Crashpad's database, or nil when the build runs no Crashpad (read on the forwarder's queue).
    ///   - environment: The process environment.
    public static func forThisApp(policy: CrashReportingPolicy, sends: Bool, stateFile: URL, consent: Consent,
                                  devOptInKey: String, database: @escaping @Sendable () -> URL?,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> ChromiumMinidumpForwarder {
        let base = baseMode(policy: policy, sends: sends, devOptInKey: devOptInKey, environment: environment)
        return ChromiumMinidumpForwarder(
            database: database, stateFile: stateFile, mainExecutableName: Bundle.main.executableURL?.lastPathComponent,
            mode: { Self.mode(base: base, consent: consent.decisionForPass()) }, labels: Labels(policy: policy),
            uploader: URLSessionMinidumpUploader(dsn: CrashReporter.dsn))
    }

    /// The mode without the hang report decision: `.discard` (reports off or a test process), `.summary` (a build
    /// that never sends hang reports), or `.upload` (it does, with consent; see ``mode(base:consent:)``).
    static func baseMode(policy: CrashReportingPolicy, sends: Bool, devOptInKey: String, environment: [String: String]) -> Mode {
        guard sends, !CrashReportingPolicy.isTestProcess(environment) else { return .discard }
        let hangReportsPossible = policy.channel == .nightly || (policy.channel == .dev && environment[devOptInKey] == "1")
        return hangReportsPossible ? .upload : .summary
    }

    /// A pass's mode: an `.upload` base uploads only with the hang report decision on, gives summaries with it off,
    /// and waits while it is unknown.
    static func mode(base: Mode, consent: @autoclosure () -> Bool?) -> Mode {
        guard base == .upload else { return base }
        switch consent() {
        case true?: return .upload
        case false?: return .summary
        case nil: return .wait
        }
    }
}
