public import CmuxNextWakeups

/// When the launch starts Cloud (plans/cmux-next/chrome-parity/p08-startup.md, task 020): never before the
/// first frame. Once startup completes by default, as Chrome posts non-visible work through
/// `AfterStartupTaskUtils::PostTask` (chrome/browser/after_startup_task_utils.cc); right after the first
/// frame, or in the next frame when that already passed, once a visible need says so (``need()``: a window
/// that shows, or waits off screen for, a Cloud machine's workspace).
///
/// The need comes from the place that knows it, when it knows it: the window restore makes its saved
/// windows after the first frame, so a decision read at the first frame would never see them.
///
/// `start` is injected (tests count it) and must be idempotent: an earlier need (a sign-in, a Cloud
/// action) may have started Cloud already.
///
/// ```swift
/// let post = CloudStartPost(startup: order.startup, start: { services.startCloudNow() })
/// post.post()   // after startup
/// post.need()   // a restored window shows a Cloud machine: after the first frame instead
/// ```
@MainActor
public final class CloudStartPost {
    private weak var startup: StartupScheduler?
    private let start: @MainActor @Sendable () -> Void
    private var needPosted = false

    /// - Parameters:
    ///   - startup: The launch's scheduler (held weakly: the post never keeps it alive).
    ///   - start: Starts Cloud (idempotent).
    public init(startup: StartupScheduler, start: @escaping @MainActor @Sendable () -> Void) {
        self.startup = startup
        self.start = start
    }

    /// Posts the default start: ``LaunchStart/cloud``, under its name at its class's priority (after startup completes).
    public func post() {
        guard let startup else { return }
        LaunchStart.cloud.post(on: startup, start)
    }

    /// A visible need: Cloud starts right after the first frame (in the next frame once it passed),
    /// before startup completes. Once per launch; nothing runs after quit began.
    public func need() {
        guard !needPosted else { return }
        needPosted = true
        startup?.post(.afterFirstFrame, "Cloud.startNeeded", on: .main, start)
    }
}
