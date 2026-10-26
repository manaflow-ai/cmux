#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

/// Builds `debug.startup`'s ``StartupReport`` (p08-startup task 008): it keeps what the first committed
/// frame held when it commits, and reads the launch marks and its sources when asked. Read-only for the
/// control call. Debug and bench-hooks builds only.
///
/// The scheduler and the action catalog's main-thread read are sources the composition root sets once
/// their owners exist (tasks 012 and 092); until then their fields are `null`.
///
/// ```swift
/// let recorder = StartupReportRecorder(launch: { DebugTimings.launchMarksNow })
/// recorder.firstFrameCommitted(contentSubviews: window.contentView?.subviews ?? [], viewsBuilt: panes)
/// let reply = try recorder.report.foundationObject()
/// ```
@MainActor
public final class StartupReportRecorder {
    /// The StartupScheduler's tasks and completion, given process start on the `CLOCK_UPTIME_RAW`
    /// nanosecond clock its records use.
    public var scheduler: ((_ processStartNanos: UInt64) -> StartupReport.Scheduler)?
    /// The main thread's wait for the action catalog's launch build, nil before its read.
    public var actionCatalogMainWaitMs: (() -> Double?)?
    /// What the first committed frame held, nil before it.
    public private(set) var firstFrame: StartupReport.FirstFrame?

    private let launch: @Sendable () -> LaunchMarks
    private let threads: any StartupThreadSource

    /// - Parameters:
    ///   - launch: A copy of the launch marks now (their owner keeps them under its lock).
    ///   - threads: The thread list read at the first frame.
    public init(launch: @escaping @Sendable () -> LaunchMarks, threads: any StartupThreadSource = SystemStartupThreads()) {
        self.launch = launch
        self.threads = threads
    }

    /// Keeps what the first window's first committed frame held: its content view's subviews, back to
    /// front, the pane views built and the threads. Later calls change nothing.
    public func firstFrameCommitted(contentSubviews: [NSView], viewsBuilt: Int) {
        guard firstFrame == nil else { return }
        firstFrame = StartupReport.FirstFrame(layerTree: contentSubviews.map { String(describing: type(of: $0)) },
                                              viewsBuilt: viewsBuilt, threads: threads.threads())
    }

    /// The report now.
    public var report: StartupReport {
        var report = StartupReport(launch: launch())
        report.scheduler = scheduler?(LaunchMarks.uptimeNanos(of: LaunchMarks.processStart))
        report.firstFrame = firstFrame
        report.actionCatalogMainWaitMs = actionCatalogMainWaitMs?()
        return report
    }
}
#endif
