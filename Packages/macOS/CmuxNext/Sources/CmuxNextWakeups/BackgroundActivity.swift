/// A repeating maintenance job that the system runs when the Mac can best afford it: a job whose
/// result nobody waits for, such as reading logs that other processes write.
///
/// The system scheduler (``SystemBackgroundActivityScheduler``, `NSBackgroundActivityScheduler`) puts
/// the run anywhere in `interval ± tolerance`, together with the maintenance of other apps, and holds
/// it while the Mac is busy, hot or asleep. This follows Chrome on Android, which gives its periodic
/// background jobs to the OS job scheduler and not to a timer of its own
/// (components/background_task_scheduler/README.md); Chrome's own task queues run such work at
/// `TaskPriority::BEST_EFFORT` (base/task/task_traits.h).
public struct BackgroundActivity: Sendable, Equatable {
    /// The scheduler's identifier: reverse DNS, unique for each app build (start it with the bundle id).
    public let identifier: String
    /// The ``WakeupLedger`` owner that each run is counted under.
    public let owner: String
    /// The time between two runs.
    public let interval: Duration
    /// How much earlier or later than its due time the system can start a run.
    public let tolerance: Duration

    /// - Parameters:
    ///   - identifier: Reverse DNS, unique for each app build.
    ///   - owner: The ``WakeupLedger`` owner of the runs.
    ///   - interval: The time between two runs.
    ///   - tolerance: How far the system can move a run from its due time.
    public init(identifier: String, owner: String, interval: Duration, tolerance: Duration) {
        self.identifier = identifier
        self.owner = owner
        self.interval = interval
        self.tolerance = tolerance
    }
}

/// Runs ``BackgroundActivity`` jobs. The app gives ``SystemBackgroundActivityScheduler``; tests give a
/// scheduler that they fire themselves.
public protocol BackgroundActivityScheduling: Sendable {
    /// Runs `body` off the main thread about every `activity.interval` (within its tolerance) until the
    /// returned run is invalidated. The first run comes about one interval after this call, and a run
    /// ends before the next one starts.
    func schedule(_ activity: BackgroundActivity, body: @escaping @Sendable () async -> Void) -> any BackgroundActivityRun
}

/// One scheduled ``BackgroundActivity``. To pause or change it, its owner invalidates it and schedules a
/// new one (the system scheduler cannot change a scheduled interval).
public protocol BackgroundActivityRun: AnyObject {
    /// Stops the runs. A run that has started finishes. A second call does nothing.
    func invalidate()
}
