import CmuxNextHangReports
import CmuxNextLaunch
import CmuxNextWakeups

/// The end of the launch's slow-launch ring (p08-startup-111, plans/cmux-next/chrome-parity/p08-startup.md): at
/// `startup_complete` the ring is freed; only a launch whose first frame missed its p95 budget keeps its events,
/// which become a ``HangReport/LaunchTrace`` off the main thread and go to the hang reports controller. A launch whose
/// reports carry no trace frees the ring as soon as the features say so.
///
/// Chrome's background tracing ends a scenario the same way: the ring is finalized and uploaded only when the
/// scenario's trigger fired, else dropped (content/browser/tracing/background_tracing_manager_impl.cc).
///
/// ```swift
/// SlowLaunchReporting(ring: recorders.ring, startup: order.startup, mainWork: order.mainWork, work: services.work) {
///     hangReports.noteLaunchTrace($0)
/// }.install(sends: hangReports.sendsLaunchTrace)
/// ```
@MainActor
struct SlowLaunchReporting {
    /// The launch's ring; nil when hang reports were off at launch.
    let ring: StartupTrace.SlowLaunchRing?
    /// The launch's startup scheduler: its completion frees the ring, and its log holds the startup tasks.
    let startup: StartupScheduler
    /// Where the trace is handed back to the main thread.
    let mainWork: MainWorkScheduler
    /// Where the trace is built, off the main thread.
    let work: BackgroundWork
    /// Takes a slow launch's trace, on the main thread.
    let deliver: @MainActor @Sendable (HangReport.LaunchTrace) -> Void

    /// Frees the ring at once when `sends` is false (reports carry no launch trace); else at `startup_complete`,
    /// keeping its events only for a launch past its budget.
    func install(sends: Bool) {
        guard let ring else { return }
        guard sends else {
            ring.finish(keeping: false)
            return
        }
        let log = startup.log, mainWork = mainWork, work = work, deliver = deliver
        // After LaunchOrder's own completion observer, which marks startup_complete.<reason> and startup_complete.
        startup.whenComplete { _ in
            let record = LaunchAggregate.Record(marks: DebugTimings.launchMarksNow.all)
            guard let launch = ring.finish(keeping: record.map(HangReport.LaunchTrace.exceedsBudget) ?? false), let record else { return }
            work.post(.bestEffort, mayBlock: .cpu) {
                guard let trace = Self.trace(of: launch, record: record, tasks: log.records) else { return }
                mainWork.postFromAnyThread(.background, owner: "HangReports.launchTrace") { deliver(trace) }
            }
        }
    }

    /// The report's trace of a slow launch: the ring's events and the startup tasks of `tasks`, the ring's overwritten
    /// records counted as dropped, in range (``HangReport/LaunchTrace/bounded``); nil when `record` was within its budget.
    nonisolated static func trace(of launch: StartupTrace.SlowLaunchRing.Launch, record: LaunchAggregate.Record,
                                  tasks: [StartupTaskLog.Record]) -> HangReport.LaunchTrace? {
        let events = launch.events(adding: tasks).map { event in
            HangReport.LaunchTrace.Event(startMicros: event.startMicros, durationMicros: event.durationMicros, kind: Self.kind(event.kind),
                                         name: event.name)
        }
        return HangReport.LaunchTrace(launch: record, events: events, dropped: launch.overwritten)?.bounded
    }

    /// The report's kind of a ring event.
    nonisolated static func kind(_ kind: StartupTrace.SlowLaunchRing.Event.Kind) -> HangReport.LaunchTrace.Kind {
        switch kind {
        case .mark: .mark
        case .mainTask: .mainTask
        case .laneTask: .laneTask
        case .mainTurn: .mainTurn
        case .laneJob: .laneJob
        }
    }
}
