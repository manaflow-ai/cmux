public import CmuxNextWakeups

/// Runs each Chromium bookmark store's sync in the main thread's idle time once the store's events have
/// settled (the App's `BookmarkChromiumSync`): a settle deadline per store (`background`) that each later
/// event restarts, then an idle task with a `maxDelay`, so a busy main thread still runs it (Chrome's
/// `ThreadScheduler::PostIdleTask`, third_party/blink/public/platform/scheduler). An idle task posted
/// before its store's settle restarted does nothing: the restarted settle posts the one that runs.
@MainActor
public final class BookmarkSyncSettle {
    /// Posts `body` as an idle task of `owner` that runs by `maxDelay` (`MainWorkScheduler.postIdle`).
    public typealias PostIdle = @MainActor (_ owner: String, _ maxDelay: Duration, _ body: @escaping @MainActor () -> Void) -> Void

    /// How long a store's events must pause before its sync.
    public let settle: Duration
    /// The longest a settled sync waits for idle time before it runs anyway.
    public let maxDelay: Duration
    private let deadlines: MainDeadlineScheduler
    private let postIdle: PostIdle
    /// Each store's settle deadline.
    private var settles: [String: MainDeadline] = [:]
    /// Bumped by each schedule of a store: an idle task of an older one does nothing.
    private var generations: [String: UInt64] = [:]

    public init(settle: Duration, maxDelay: Duration, deadlines: MainDeadlineScheduler, postIdle: @escaping PostIdle) {
        self.settle = settle
        self.maxDelay = maxDelay
        self.deadlines = deadlines
        self.postIdle = postIdle
    }

    /// Runs `work` in idle time once `store` has had no schedule for ``settle``; a later schedule of the
    /// same store starts the wait again and replaces `work`.
    public func schedule(_ store: String, _ work: @escaping @MainActor () -> Void) {
        let generation = generations[store, default: 0] &+ 1
        generations[store] = generation
        let timer = settles[store] ?? MainDeadline(owner: "BookmarkChromiumSync.settle", workClass: .background, scheduler: deadlines)
        settles[store] = timer
        timer.schedule(after: settle) { [weak self] in
            guard let self else { return }
            postIdle("BookmarkChromiumSync.sync", maxDelay) { [weak self] in
                guard let self, generations[store] == generation else { return }
                work()
            }
        }
    }
}
