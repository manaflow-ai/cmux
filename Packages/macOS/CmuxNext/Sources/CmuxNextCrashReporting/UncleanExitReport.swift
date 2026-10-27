public import CmuxNextCompat
public import Sentry

/// How the previous run ended, as the next launch sends it: one event per launch (p10-stability-203).
///
/// Chrome's clean exit beacon (components/metrics/clean_exit_beacon.cc) marks a session unclean at its start and
/// clean at a normal end; the next launch reads it and counts the unclean ends that no crash handler saw
/// (components/metrics/stability_metrics_provider.cc, `Stability.Counts2`). The run marker is cmux's beacon
/// (`AppRunMarker`); this report is its value, sent as an info or warning event tagged `exit_outcome`, which
/// `scripts/cmux-next/stability-health.py` counts per 1k sessions. The event holds the outcome, the fatal signal's
/// number and two flags of the run, nothing else: no exception reason, no path, no crash key.
public nonisolated struct UncleanExitReport: Sendable, Equatable {
    /// How the run ended (the `exit_outcome` tag's values).
    public enum Outcome: String, Sendable, CaseIterable {
        /// A normal quit, or a quit someone asked for (a requested-quit signal, a quit that had begun).
        case clean
        /// The run's fatal-signal handler recorded a signal (`run.signal`).
        case signal
        /// The run ended on an uncaught Objective-C exception (`run.exception`).
        case exception
        /// A crash path began and wrote the crash keys, but recorded no signal or exception: its deadline or
        /// the crash watcher ended the run (`CrashDeadline`, `CrashWatcher`).
        case crashCaught = "crash-caught"
        /// No handler ran, in the same boot: `kill -9`, jetsam or Force Quit. Chrome's beacon number.
        case uncleanNoReport = "unclean-no-report"
        /// No handler ran and the Mac started again since (power loss, a kernel panic, a forced restart),
        /// counted apart as Chrome counts an unclean exit while the system session ended.
        case systemShutdown = "system-shutdown"
    }

    /// How the run ended.
    public let outcome: Outcome
    /// The fatal signal's number when ``outcome`` is ``Outcome/signal``; else nil.
    public let signal: Int32?
    /// The run lived past the quick-crash window.
    public let survived: Bool
    /// The run itself followed a crash or a quick kill.
    public let followedRestart: Bool

    /// The report of a run that left these records.
    ///
    /// - Parameters:
    ///   - endedAsAsked: The run quit normally or as asked (`PreviousRun.endedAsAsked`).
    ///   - signal: The signal its handler recorded, if any.
    ///   - exception: It recorded an uncaught exception.
    ///   - crashPathRan: Its crash path wrote the crash keys (`run.crashkeys`).
    ///   - bootChanged: The Mac booted again after the run (`kern.bootsessionuuid` differs).
    ///   - survived: It lived past the quick-crash window.
    ///   - followedRestart: It followed a crash or a quick kill.
    public init(endedAsAsked: Bool, signal: Int32?, exception: Bool, crashPathRan: Bool, bootChanged: Bool,
                survived: Bool, followedRestart: Bool) {
        let outcome = Self.outcome(endedAsAsked: endedAsAsked, signal: signal, exception: exception,
                                   crashPathRan: crashPathRan, bootChanged: bootChanged)
        self.outcome = outcome
        self.signal = outcome == .signal ? signal : nil
        self.survived = survived
        self.followedRestart = followedRestart
    }

    /// The first record that names the end. An uncaught exception aborts, so its run records SIGABRT too: the
    /// exception is the cause. A handler's record is a crash whatever the boot (`PreviousRun.uncleanExit`).
    private static func outcome(endedAsAsked: Bool, signal: Int32?, exception: Bool, crashPathRan: Bool,
                                bootChanged: Bool) -> Outcome {
        if endedAsAsked { return .clean }
        if exception { return .exception }
        if signal != nil { return .signal }
        if crashPathRan { return .crashCaught }
        return bootChanged ? .systemShutdown : .uncleanNoReport
    }

    /// The event: an info message for a clean end, a warning otherwise, one Sentry issue per outcome.
    public func event() -> Event {
        let event = Event(level: outcome == .clean ? .info : .warning)
        event.message = SentryMessage(formatted: "previous run ended: \(outcome.rawValue)")
        event.fingerprint = ["previous_run_exit", outcome.rawValue]
        var tags = [
            "exit_outcome": outcome.rawValue,
            "exit_survived": survived ? "yes" : "no",
            "exit_followed_restart": followedRestart ? "yes" : "no",
        ]
        if let signal { tags["exit_signal"] = String(signal) }
        event.tags = tags
        return event
    }
}

extension CrashReporter {
    /// Sends `report` on `work`'s files lane (the SDK writes the envelope to disk), with a clean scope: this
    /// launch's breadcrumbs do not describe the run that ended. Nothing is posted or sent while crash reporting is
    /// off (consent, managed policy, a DEV build without `CMUX_NEXT_DEV_SENTRY=1`, tests).
    /// - Returns: whether the send was posted.
    @discardableResult
    public func reportPreviousExit(_ report: UncleanExitReport, work: any MayBlockRunner) -> Bool {
        reportPreviousExit(report, work: work, consented: { [self] in isStarted }, capture: Self.sentryCapture)
    }

    /// ``reportPreviousExit(_:work:)`` with its consent and capture seams (tests pass their own).
    func reportPreviousExit(_ report: UncleanExitReport, work: any MayBlockRunner,
                            consented: @escaping @Sendable () -> Bool, capture: @escaping ScopedCapture) -> Bool {
        guard consented() else { return false }
        work.postFiles(.bestEffort, shutdown: .skipOnShutdown) {
            guard consented() else { return }
            capture(report.event(), Scope())
        }
        return true
    }
}
