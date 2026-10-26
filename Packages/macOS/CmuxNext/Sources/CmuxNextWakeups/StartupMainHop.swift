import Foundation

/// The main-thread seam of ``StartupScheduler``: how a post from another thread reaches main, and
/// how the completion is posted to a later main turn.
///
/// Chrome hops an after-startup post made off the UI thread to it as a USER_VISIBLE task, so the
/// hop is not itself held as an after-startup task (`AfterStartupTaskUtils::PostTask`,
/// chrome/browser/after_startup_task_utils.cc), and posts the completion signal instead of running
/// it inline (`MaybeSignalStartupComplete`), so it never runs inside a caller's frame or during
/// shutdown. The app uses ``userVisible``; tests inject a hop they run by hand.
///
/// ```swift
/// let hop = StartupMainHop { work in queued.append(work) }  // a test's hand-run hop
/// ```
public struct StartupMainHop: Sendable {
    /// Queues main-actor work for a later main turn; callable from any thread.
    public typealias Hop = @Sendable (_ work: @escaping @MainActor @Sendable () -> Void) -> Void

    private let hop: Hop

    /// - Parameter hop: Queues work for a later main turn, from any thread.
    public init(_ hop: @escaping Hop) {
        self.hop = hop
    }

    /// The app's hop: one main-actor task at ``WorkPriority/userVisible``.
    public static var userVisible: StartupMainHop {
        StartupMainHop { work in
            // task-owner: one hop to main; the scheduler owns what it queues there
            Task(priority: WorkPriority.userVisible.taskPriority) { @MainActor in work() }
        }
    }

    /// Runs `work` on a later main turn, never inline.
    public func later(_ work: @escaping @MainActor @Sendable () -> Void) {
        hop(work)
    }

    /// Runs `work` now when called on the main thread, else on a later main turn.
    public func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            // main-proof: guarded by Thread.isMainThread above
            MainActor.assumeIsolated(work)
        } else {
            hop(work)
        }
    }
}
