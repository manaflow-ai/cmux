public import CmuxNextWakeups

/// When the launch starts Cloud (plans/cmux-next/chrome-parity/p08-startup.md, task 020): never before the
/// first frame. Right after it when a window shows a remote machine's workspace (it waits for its machine),
/// else once startup completes, as Chrome posts non-visible work through `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc).
///
/// The decision and the start are injected, so tests post it on their own scheduler. `start` must be
/// idempotent: an earlier need (a sign-in callback) may have started Cloud already.
///
/// ```swift
/// CloudStartPost(showsRemoteWorkspace: { windowOnAnotherMachine() }, start: { services.startCloudNow() })
///     .post(on: order.startup)
/// ```
public struct CloudStartPost {
    /// Whether a window shows a workspace of a machine other than this Mac, read once after the first frame.
    public let showsRemoteWorkspace: @MainActor @Sendable () -> Bool
    /// Starts Cloud; a second call does nothing.
    public let start: @MainActor @Sendable () -> Void

    /// - Parameters:
    ///   - showsRemoteWorkspace: Read once, in the first afterFirstFrame turn.
    ///   - start: Starts Cloud (idempotent).
    public init(showsRemoteWorkspace: @escaping @MainActor @Sendable () -> Bool, start: @escaping @MainActor @Sendable () -> Void) {
        self.showsRemoteWorkspace = showsRemoteWorkspace
        self.start = start
    }

    /// Posts the start: one afterFirstFrame task that starts Cloud at once or posts it after startup.
    public func post(on startup: StartupScheduler) {
        let shows = showsRemoteWorkspace, start = start
        startup.post(.afterFirstFrame, "Cloud.startIfShown", on: .main) { [weak startup] in
            if shows() { start() } else { startup?.post(.afterStartup, "Cloud.start", on: .main, start) }
        }
    }
}
