import Foundation

/// ``BackgroundActivityScheduling`` on `NSBackgroundActivityScheduler`, at `.background` quality of
/// service and repeating. Each run is counted in the ledger under the activity's owner.
public struct SystemBackgroundActivityScheduler: BackgroundActivityScheduling {
    private let ledger: WakeupLedger

    /// - Parameter ledger: Where each run is counted.
    public init(ledger: WakeupLedger = .shared) {
        self.ledger = ledger
    }

    /// Schedules `body` on an `NSBackgroundActivityScheduler` with `activity`'s identifier, interval and tolerance.
    public func schedule(_ activity: BackgroundActivity, body: @escaping @Sendable () async -> Void) -> any BackgroundActivityRun {
        let scheduler = NSBackgroundActivityScheduler(identifier: activity.identifier)
        scheduler.interval = activity.interval.inSeconds
        scheduler.tolerance = activity.tolerance.inSeconds
        scheduler.qualityOfService = .background
        scheduler.repeats = true
        let ledger = ledger, owner = activity.owner
        scheduler.schedule { completion in
            let done = BackgroundActivityCompletion(completion)
            ledger.record(owner, reason: "background-activity")
            // task-owner: one run; the scheduler starts no next run until this one calls its completion handler.
            // The task takes the block's .background priority: nothing waits for maintenance.
            Task {
                await body()
                done.finished()
            }
        }
        return SystemBackgroundActivityRun(scheduler)
    }
}

/// The run of one `NSBackgroundActivityScheduler`; a run that is released is invalidated.
private final class SystemBackgroundActivityRun: BackgroundActivityRun {
    private let scheduler: NSBackgroundActivityScheduler

    init(_ scheduler: NSBackgroundActivityScheduler) {
        self.scheduler = scheduler
    }

    deinit { scheduler.invalidate() }

    func invalidate() { scheduler.invalidate() }
}

/// The completion handler of one `NSBackgroundActivityScheduler` run, carried to the run's task.
// crash-allow: the handler is immutable and called once, from the run's task; NSBackgroundActivityScheduler takes it on any thread, as an asynchronous activity must
private struct BackgroundActivityCompletion: @unchecked Sendable {
    private let handler: NSBackgroundActivityScheduler.CompletionHandler

    init(_ handler: @escaping NSBackgroundActivityScheduler.CompletionHandler) {
        self.handler = handler
    }

    func finished() { handler(.finished) }
}
