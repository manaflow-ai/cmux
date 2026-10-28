public import CmuxNextControl
public import Foundation

/// The main-thread watchdog's hang sinks, set before Sentry starts: each hang still running
/// after 2 s goes to crash reporting (`MainThreadWatchdog.onHang`); each hang episode of
/// ``CrashReporter/appHangThreshold`` and up is one Sentry app hang (`MainThreadWatchdog.onHangEpisode`,
/// ``AppHangReporter``); and, when this run keeps the fatal-hang record (feature `fatalHangReports`),
/// every hang episode goes to that record (`MainThreadWatchdog.fatalHangs`), so a hang the
/// app does not survive is reported at the next launch.
///
/// The watchdog is the process's one hang watcher, as Chrome has one HangWatcher per process: Sentry's app-hang
/// tracker is off wherever these sinks are set (``hangTracking``), and they are in place before the start that
/// applies that choice, so no hang from Sentry's start on goes unreported, a launch hang included. Chrome likewise
/// starts its HangWatcher before the browser's main runs (content/app/content_main_runner_impl.cc). The app's
/// `WatchdogReporting.install` later replaces `onHang` with one that also feeds opt-in hang reports.
///
/// ```swift
/// let sinks = WatchdogHangSinks(watchdog: watchdog, keepsFatalHangRecord: true, markerFolder: folder)
/// let reporter = CrashReporter(policy: policy, hangTracking: sinks.hangTracking)
/// sinks.install(reporter: reporter)
/// reporter.start()
/// ```
public struct WatchdogHangSinks: Sendable {
    public let watchdog: MainThreadWatchdog
    /// Whether this run keeps the fatal-hang record: feature `fatalHangReports` on and a run marker whose folder the
    /// next launch reads.
    public let keepsFatalHangRecord: Bool
    /// The fatal-hang records' folder (the run marker's).
    public let markerFolder: URL

    public init(watchdog: MainThreadWatchdog, keepsFatalHangRecord: Bool, markerFolder: URL) {
        self.watchdog = watchdog
        self.keepsFatalHangRecord = keepsFatalHangRecord
        self.markerFolder = markerFolder
    }

    /// Who reports main-thread hangs this launch: the watchdog alone, its episodes the app hangs.
    public var hangTracking: CrashReporter.HangTracking { .watchdog }

    /// Sets the sinks on ``watchdog`` for `reporter`. Call before `reporter` starts Sentry. The fatal-hang record is
    /// kept only when Sentry runs in this process (``CrashReportingPolicy/shouldStart``), the consent the next
    /// launch's report also needs.
    public func install(reporter: CrashReporter) {
        watchdog.onHang = { hang in Self.send(hang, to: reporter) }
        watchdog.onHangEpisode = AppHangReporter(reporter: reporter).episodeSink
        guard keepsFatalHangRecord, reporter.policy.shouldStart else { return }
        let fatal = FatalHangRecorder(directory: markerFolder, release: reporter.policy.release, dist: reporter.policy.dist)
        watchdog.fatalHangs = MainThreadWatchdog.FatalHangSink(began: { hang, start in
            fatal.began(startUptimeNanos: start, elapsedNanos: Self.nanos(hang.duration), addresses: hang.addresses,
                        phase: hang.phase, attribution: Self.attribution(of: hang))
        }, progressed: { fatal.progressed(elapsedNanos: $0) }, ended: { fatal.ended() })
    }

    /// Sends `hang` to crash reporting; nothing while Sentry is off. Watchdog thread.
    public static func send(_ hang: MainThreadWatchdog.Hang, to reporter: CrashReporter) {
        reporter.reportHang(duration: hang.duration, addresses: hang.addresses, otherThreads: hang.otherThreads.map { ($0.name, $0.addresses) },
                            phase: hang.phase, cef: hang.cef, attribution: attribution(of: hang))
    }

    /// The scheduled task the hang's sample caught, as crash reporting names it.
    static func attribution(of hang: MainThreadWatchdog.Hang) -> MainThreadHangEvent.Attribution {
        MainThreadHangEvent.Attribution(owner: hang.attribution.owner, taskClass: hang.attribution.taskClass,
                                        location: hang.attribution.location, turnNanos: hang.attribution.turnNanos)
    }

    /// `duration` in whole nanoseconds, negative as zero.
    static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: max(Int64(0), seconds)) &* 1_000_000_000 &+ UInt64(clamping: max(Int64(0), attoseconds / 1_000_000_000))
    }
}

extension AppHangReporter {
    /// The watchdog's hang episode reports (``MainThreadWatchdog/onHangEpisode``, on its thread)
    /// to this reporter.
    public var episodeSink: @Sendable (MainThreadWatchdog.HangEpisodeEvent) -> Void {
        { [self] event in
            switch event {
            case let .blocked(hang, previous):
                noteBlocked(duration: hang.duration, previous: previous, addresses: hang.addresses,
                            otherThreads: hang.otherThreads.map { ($0.name, $0.addresses) })
            case let .ended(duration, lastReport):
                noteEnded(duration: duration, lastReport: lastReport?.duration, addresses: lastReport?.addresses ?? [],
                          otherThreads: (lastReport?.otherThreads ?? []).map { ($0.name, $0.addresses) })
            }
        }
    }
}
