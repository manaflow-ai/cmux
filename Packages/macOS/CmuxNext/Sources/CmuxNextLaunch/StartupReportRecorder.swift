#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

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
/// recorder.firstFrameCommitted(contentSubviews: window.contentView?.subviews, viewsBuilt: panes)
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
    private var threadRead: Task<Void, Never>?

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
    /// front (nil: the window had no content view), and the pane views built. The thread list is read off
    /// the main thread after this turn, so the probe adds no thread walk to the launch's main thread. Later
    /// calls change nothing.
    public func firstFrameCommitted(contentSubviews: [NSView]?, viewsBuilt: Int) {
        guard firstFrame == nil else { return }
        firstFrame = StartupReport.FirstFrame(layerTree: contentSubviews?.map { String(describing: type(of: $0)) },
                                              viewsBuilt: viewsBuilt)
        let source = threads
        threadRead = Task { [weak self] in
            let list = await Self.readThreads(source)
            self?.firstFrame?.threads = list
        }
    }

    /// Returns once the thread list the first frame asked for is in the report (at once before the first frame).
    public func threadsRead() async {
        await threadRead?.value
    }

    /// The report now.
    public var report: StartupReport {
        var report = StartupReport(launch: launch(), counters: counters())
        report.scheduler = scheduler(processStartNanos)
        report.firstFrame = firstFrame
        report.actionCatalogMainWaitMs = actionCatalogMainWaitMs()
        return report
    }

    @concurrent
    private nonisolated static func readThreads(_ source: any StartupThreadSource) async -> [StartupReport.ThreadRecord] {
        source.threads()
    }
}
#endif
