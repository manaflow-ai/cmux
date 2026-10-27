public import Foundation

/// One scheduled ``BackgroundActivityRequest``: it runs until ``invalidate()``. To pause it, invalidate
/// it; to resume or change its interval, schedule a new one.
@MainActor public protocol BackgroundActivity: AnyObject {
    /// Stops the runs; an intent posted before the call may still arrive.
    func invalidate()
}

/// Runs repeating maintenance when the OS finds it cheap, the way Chromium leaves best-effort
/// background work to the platform's scheduler (`base/task/thread_pool/thread_group.cc` runs
/// `TaskPriority::BEST_EFFORT` at background QoS) and macOS asks apps to schedule periodic work
/// (`NSBackgroundActivityScheduler`): the OS batches the wake with others inside the tolerance and
/// defers it while the Mac is busy, on battery or in Low Power Mode. Each run posts one main-actor
/// intent in the request's class; the run itself does no work. The app uses
/// ``SystemBackgroundActivityScheduler``; tests use a fake that runs the intent by hand.
@MainActor public protocol BackgroundActivityScheduling: AnyObject {
    /// Starts `request`; each run posts `intent` on the main thread until the activity is invalidated.
    func schedule(_ request: BackgroundActivityRequest,
                  _ intent: @escaping @MainActor @Sendable () -> Void) -> any BackgroundActivity
}

/// ``BackgroundActivityScheduling`` on `NSBackgroundActivityScheduler`: each run records one wake under
/// the request's owner in the ``WakeupLedger`` and posts the intent on the app's ``MainWorkScheduler``.
///
/// ```swift
/// let activities = SystemBackgroundActivityScheduler(work: mainWork)
/// let poll = activities.schedule(BackgroundActivityRequest(
///     identifier: "com.cmuxterm.next.poll", owner: "Poll.refresh",
///     interval: .seconds(120), tolerance: .seconds(30))) { poller.refresh() }
/// poll.invalidate()
/// ```
@MainActor public final class SystemBackgroundActivityScheduler: BackgroundActivityScheduling {
    private let work: MainWorkScheduler
    private let ledger: WakeupLedger

    /// - Parameters:
    ///   - work: The app's one main-thread scheduler; intents are posted on it.
    ///   - ledger: Where each run is recorded.
    public init(work: MainWorkScheduler, ledger: WakeupLedger = .shared) {
        self.work = work
        self.ledger = ledger
    }

    public func schedule(_ request: BackgroundActivityRequest,
                         _ intent: @escaping @MainActor @Sendable () -> Void) -> any BackgroundActivity {
        let scheduler = NSBackgroundActivityScheduler(identifier: request.identifier)
        scheduler.repeats = true
        scheduler.interval = request.interval.inSeconds
        scheduler.tolerance = request.tolerance.inSeconds
        scheduler.qualityOfService = .background
        scheduler.schedule(Self.run(request, owner: work.board.owner(request.owner), on: work, ledger: ledger, intent))
        return Activity(scheduler: scheduler)
    }

    /// The scheduler's block: it runs on a pool thread, so it is made outside the main actor.
    nonisolated private static func run(
        _ request: BackgroundActivityRequest, owner: MainTaskOwner, on work: MainWorkScheduler, ledger: WakeupLedger,
        _ intent: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void {
        { completion in
            ledger.record(request.owner, reason: "activity")
            work.postFromAnyThread(request.workClass, owner: owner, intent)
            completion(.finished)
        }
    }

    /// One `NSBackgroundActivityScheduler`, created, scheduled and invalidated on the main actor.
    @MainActor private final class Activity: BackgroundActivity {
        private let scheduler: NSBackgroundActivityScheduler

        init(scheduler: NSBackgroundActivityScheduler) {
            self.scheduler = scheduler
        }

        func invalidate() { scheduler.invalidate() }
    }
}
