public import CmuxNextHangReports
public import CmuxNextWakeups

extension StartupTrace.SlowLaunchRing {
    /// The end of the launch's ring (p08-startup-111, plans/cmux-next/chrome-parity/p08-startup.md): at `startup`'s
    /// completion the ring is freed; only a launch whose first frame missed its p95 budget keeps its events, which
    /// become a ``HangReport/LaunchTrace`` on `work`'s cpu lane and reach `deliver` on the main thread. With `sends`
    /// false (reports carry no launch trace) the ring is freed at once.
    ///
    /// Chrome's background tracing ends a scenario the same way: the ring is finalized and uploaded only when the
    /// scenario's trigger fired, else dropped (content/browser/tracing/background_tracing_manager_impl.cc).
    ///
    /// ```swift
    /// ring?.reportAtCompletion(of: order.startup, sends: hangReports.sendsLaunchTrace, marks: { DebugTimings.launchMarksNow.all },
    ///                          mainWork: mainWork, work: services.work) { hangReports.noteLaunchTrace($0) }
    /// ```
    ///
    /// - Parameters:
    ///   - startup: The launch's startup scheduler: its completion frees the ring, and its log holds the startup tasks.
    ///   - sends: Whether this launch's reports carry a launch trace.
    ///   - marks: The launch marks so far (each name once, milliseconds since process start), read at completion after
    ///     `LaunchOrder` marked `startup_complete.<reason>` and `startup_complete`.
    ///   - mainWork: Where the trace is handed back to the main thread.
    ///   - work: Where the trace is built, off the main thread.
    ///   - deliver: Takes a slow launch's trace.
    @MainActor
    public func reportAtCompletion(of startup: StartupScheduler, sends: Bool, marks: @escaping @MainActor () -> [(name: String, ms: Double)],
                                   mainWork: MainWorkScheduler, work: BackgroundWork,
                                   deliver: @escaping @MainActor @Sendable (HangReport.LaunchTrace) -> Void) {
        guard sends else {
            finish(keeping: false)
            return
        }
        let log = startup.log
        startup.whenComplete { [self] _ in
            let record = LaunchAggregate.Record(marks: marks())
            guard let launch = finish(keeping: record.map(HangReport.LaunchTrace.exceedsBudget) ?? false), let record else { return }
            work.post(.bestEffort, mayBlock: .cpu) {
                guard let trace = launch.trace(of: record, tasks: log.records) else { return }
                mainWork.postFromAnyThread(.background, owner: "HangReports.launchTrace") { deliver(trace) }
            }
        }
    }
}

extension StartupTrace.SlowLaunchRing.Launch {
    /// The report's trace of this launch: the ring's events and the startup tasks of `tasks`, the ring's overwritten
    /// records counted as dropped, in range (``HangReport/LaunchTrace/bounded``); nil when `record` was within its budget.
    public func trace(of record: LaunchAggregate.Record, tasks: [StartupTaskLog.Record]) -> HangReport.LaunchTrace? {
        let events = self.events(adding: tasks).map { event in
            HangReport.LaunchTrace.Event(startMicros: event.startMicros, durationMicros: event.durationMicros,
                                         kind: event.kind.reportKind, name: event.name)
        }
        return HangReport.LaunchTrace(launch: record, events: events, dropped: overwritten)?.bounded
    }
}

extension StartupTrace.SlowLaunchRing.Event.Kind {
    /// The report's kind of a ring event.
    public var reportKind: HangReport.LaunchTrace.Kind {
        switch self {
        case .mark: .mark
        case .mainTask: .mainTask
        case .laneTask: .laneTask
        case .mainTurn: .mainTurn
        case .laneJob: .laneJob
        }
    }
}
