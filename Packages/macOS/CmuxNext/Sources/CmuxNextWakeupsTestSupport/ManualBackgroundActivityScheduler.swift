import CmuxNextCompat
public import CmuxNextWakeups

/// A ``BackgroundActivityScheduling`` that runs only when the test fires it: it keeps every activity
/// scheduled on it and which ones were invalidated, and ``fire()`` runs the live ones once, as the
/// system does when they come due.
///
/// ```swift
/// let activities = ManualBackgroundActivityScheduler()
/// let service = Service(activities: activities)
/// service.start()
/// #expect(activities.live.map(\.interval) == [.seconds(300)])
/// await activities.fire()
/// ```
public final class ManualBackgroundActivityScheduler: BackgroundActivityScheduling, Sendable {
    private struct Entry {
        let activity: BackgroundActivity
        let body: @Sendable () async -> Void
        var isInvalidated = false
    }

    private let entries = Mutex<[Entry]>([])

    public init() {}

    public func schedule(_ activity: BackgroundActivity, body: @escaping @Sendable () async -> Void) -> any BackgroundActivityRun {
        let index = entries.withLock { entries in
            entries.append(Entry(activity: activity, body: body))
            return entries.count - 1
        }
        return Run(scheduler: self, index: index)
    }

    /// Every activity scheduled so far, the oldest first.
    public var scheduled: [BackgroundActivity] { entries.withLock { $0.map(\.activity) } }

    /// The activities that are not invalidated, the oldest first.
    public var live: [BackgroundActivity] { entries.withLock { $0.filter { !$0.isInvalidated }.map(\.activity) } }

    /// Runs the body of each live activity once, one after the other, and returns when they end.
    /// - Returns: How many bodies ran.
    @discardableResult
    public func fire() async -> Int {
        let bodies = entries.withLock { $0.filter { !$0.isInvalidated }.map(\.body) }
        for body in bodies { await body() }
        return bodies.count
    }

    private func invalidate(_ index: Int) {
        entries.withLock { $0[index].isInvalidated = true }
    }

    private final class Run: BackgroundActivityRun {
        private let scheduler: ManualBackgroundActivityScheduler
        private let index: Int

        init(scheduler: ManualBackgroundActivityScheduler, index: Int) {
            self.scheduler = scheduler
            self.index = index
        }

        func invalidate() { scheduler.invalidate(index) }
    }
}
