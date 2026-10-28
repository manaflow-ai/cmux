#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
public import CmuxNextWakeups

/// Builds `debug.startup`'s ``StartupReport`` (p08-startup task 008): it keeps what the first committed
/// frame held when it commits, and reads the launch marks and its sources when asked. Read-only for the
/// control call. Debug and bench-hooks builds only.
///
/// The composition root names every source in ``init(launch:processStartNanos:counters:scheduler:actionCatalogMainWaitMs:threads:)``;
/// a source whose owner is not in this build returns nil and its fields read `null`.
///
/// ```swift
/// let recorder = StartupReportRecorder(launch: { DebugTimings.launchMarksNow },
///                                      processStartNanos: DebugTimings.processStartUptimeNanos,
///                                      counters: { nil }, scheduler: { _ in nil }, actionCatalogMainWaitMs: { nil })
/// recorder.firstFrameCommitted(contentSubviews: window.contentView?.subviews, viewsBuilt: panes,
///                               readThreads: StartupReportRecorder.threadRead(on: work, replyOn: mainWork))
/// let reply = try recorder.report.foundationObject()
/// ```
@MainActor
public final class StartupReportRecorder {
    /// What the first committed frame held, nil before it.
    public private(set) var firstFrame: StartupReport.FirstFrame?

    private let launch: @Sendable () -> LaunchMarks
    private let processStartNanos: UInt64
    private let counters: () -> StartupReport.Counters?
    private let scheduler: (_ processStartNanos: UInt64) -> StartupReport.Scheduler?
    private let actionCatalogMainWaitMs: () -> Double?
    private let threads: any StartupThreadSource

    /// Reads `source`'s thread list off the main thread and hands it to `done` in a classed main-thread post.
    public typealias ThreadRead = @MainActor (_ source: any StartupThreadSource,
                                              _ done: @escaping @MainActor @Sendable ([StartupReport.ThreadRecord]) -> Void) -> Void

    /// The app's ``ThreadRead``: a `cpu` lane item of `work`, its reply a background post on `mainWork` (Chrome's
    /// `PostTaskAndReplyWithResult`, base/task/task_runner.h).
    public static func threadRead(on work: BackgroundWork, replyOn mainWork: MainWorkScheduler) -> ThreadRead {
        { source, done in
            work.run(.userVisible, mayBlock: .cpu) { source.threads() }
                .reply(on: mainWork, class: .background, owner: "startup.report.threads", done)
        }
    }

    /// - Parameters:
    ///   - launch: A copy of the launch marks now (their owner keeps them under its lock).
    ///   - processStartNanos: Process start on the `CLOCK_UPTIME_RAW` nanosecond clock, read once at launch
    ///     (the launch's one `LaunchClock` pairing): the zero of every task time.
    ///   - counters: The launch counters read so far (task 007), nil with no counter source.
    ///   - scheduler: The StartupScheduler's tasks and completion (task 012), given `processStartNanos`; nil
    ///     with no scheduler.
    ///   - actionCatalogMainWaitMs: The main thread's wait for the action catalog's launch build (task 092),
    ///     nil before its read or with no catalog source.
    ///   - threads: The thread list read right after the first frame.
    public init(launch: @escaping @Sendable () -> LaunchMarks, processStartNanos: UInt64,
                counters: @escaping () -> StartupReport.Counters?,
                scheduler: @escaping (_ processStartNanos: UInt64) -> StartupReport.Scheduler?,
                actionCatalogMainWaitMs: @escaping () -> Double?,
                threads: any StartupThreadSource = SystemStartupThreads()) {
        self.launch = launch
        self.processStartNanos = processStartNanos
        self.counters = counters
        self.scheduler = scheduler
        self.actionCatalogMainWaitMs = actionCatalogMainWaitMs
        self.threads = threads
    }

    /// Keeps what the first window's first committed frame held: its content view's subviews, back to
    /// front (nil: the window had no content view), and the pane views built. `readThreads` reads the thread
    /// list off the main thread after this turn, so the probe adds no thread walk to the launch's main thread.
    /// Later calls change nothing.
    public func firstFrameCommitted(contentSubviews: [NSView]?, viewsBuilt: Int, readThreads: ThreadRead) {
        guard firstFrame == nil else { return }
        firstFrame = StartupReport.FirstFrame(layerTree: contentSubviews?.map { String(describing: type(of: $0)) },
                                              viewsBuilt: viewsBuilt)
        readThreads(threads) { [weak self] list in self?.firstFrame?.threads = list }
    }

    /// The report now.
    public var report: StartupReport {
        var report = StartupReport(launch: launch(), counters: counters())
        report.scheduler = scheduler(processStartNanos)
        report.firstFrame = firstFrame
        report.actionCatalogMainWaitMs = actionCatalogMainWaitMs()
        return report
    }
}
#endif
