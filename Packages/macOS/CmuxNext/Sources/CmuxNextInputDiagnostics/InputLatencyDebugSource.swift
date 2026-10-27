public import CmuxNextControl
public import CmuxNextInput
public import CmuxNextInputCore
public import CmuxNextWakeups

/// `debug.input` section `latency` from the app's input latency tracker (p04-input-002, 004): the slots the tracker
/// closes, folded off the main thread by an ``InputLatencyReporter``. ``follow(vsyncNanos:)`` makes the reporter the
/// tracker's batch sink (one batch per half ring). Each read and reset first hands over the slots closed since the last
/// batch, in one main-thread copy on the app's scheduler (an `automation` task, behind the person's input), so a read
/// after a few keys counts every one of them.
///
/// ```swift
/// let source = InputLatencyDebugSource(reporter: reporter, tracker: tracker, mainWork: mainWork)
/// source.follow { 16_666_667 }  // once, on main, before the first input
/// router.register([DebugInput(sources: [source]).method])
/// ```
public nonisolated struct InputLatencyDebugSource: DebugInputSource {
    /// The reporter that folds the tracker's batches.
    public let reporter: InputLatencyReporter
    private let tracker: InputLatencyTracker
    private let mainWork: MainWorkScheduler

    /// - Parameters:
    ///   - reporter: Folds the batches; its reader (``InputLatencyReporter/run()``) is the owner's task.
    ///   - tracker: The app's one tracker.
    ///   - mainWork: The app's main-thread scheduler, which runs each read's hand-over.
    public init(reporter: InputLatencyReporter, tracker: InputLatencyTracker, mainWork: MainWorkScheduler) {
        self.reporter = reporter
        self.tracker = tracker
        self.mainWork = mainWork
    }

    public var section: DebugInputSection { .latency }

    /// Makes ``reporter`` the tracker's batch sink. Each batch carries the tracker's lost-slot count and the refresh
    /// interval `vsyncNanos` gives then (scroll frames are judged against it; 0 skips them).
    @MainActor
    public func follow(vsyncNanos: @escaping @MainActor () -> UInt64) {}

    public func read() async -> InputLatencySnapshot {
        await reporter.snapshot()
    }

    public func reset() async {
        await reporter.reset()
    }
}
