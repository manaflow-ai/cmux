/// Schedules ``BackgroundActivity`` jobs whose run is one main-actor intent, for an owner that lives on
/// the main actor (a poll whose refresh starts there). The run posts the intent and does no work
/// itself; the app posts it in a budgeted class on its ``MainWorkScheduler``, as Chromium's
/// best-effort tasks post their reply to the UI thread and do not run there
/// (base/task/thread_pool/thread_group.cc).
///
/// ```swift
/// let activities = MainIntentBackgroundActivities(activities: SystemBackgroundActivityScheduler(), work: mainWork)
/// let run = activities.schedule(BackgroundActivity(identifier: "\(bundleID).poll", owner: "Poll.refresh",
///                                                  interval: .seconds(120), tolerance: .seconds(30))) { poller.refresh() }
/// run.invalidate()
/// ```
public struct MainIntentBackgroundActivities: Sendable {
    /// Carries one run's intent to the main actor; `owner` is the activity's ``BackgroundActivity/owner``.
    public typealias Post = @Sendable (_ owner: String, _ intent: @escaping @MainActor @Sendable () -> Void) async -> Void

    private let activities: any BackgroundActivityScheduling
    private let post: Post

    /// Posts each run's intent on `work` in `workClass`, under the activity's owner.
    public init(activities: any BackgroundActivityScheduling, work: MainWorkScheduler,
                workClass: BudgetedWorkClass = .background) {
        self.init(activities: activities) { owner, intent in
            work.postFromAnyThread(workClass, owner: owner, intent)
        }
    }

    /// The app's: `NSBackgroundActivityScheduler` runs (``SystemBackgroundActivityScheduler``) posting
    /// their intent on `work` in `.background`.
    public static func system(work: MainWorkScheduler) -> MainIntentBackgroundActivities {
        MainIntentBackgroundActivities(activities: SystemBackgroundActivityScheduler(), work: work)
    }

    /// Hands each run's intent to `post` (tests queue it, or run it at once).
    public init(activities: any BackgroundActivityScheduling, post: @escaping Post) {
        self.activities = activities
        self.post = post
    }

    /// Schedules `activity`; each run hands `intent` to the main actor until the run is invalidated.
    /// An intent handed over before ``BackgroundActivityRun/invalidate()`` may still arrive after it.
    public func schedule(_ activity: BackgroundActivity,
                         intent: @escaping @MainActor @Sendable () -> Void) -> any BackgroundActivityRun {
        let post = post, owner = activity.owner
        return activities.schedule(activity) { await post(owner, intent) }
    }
}
