import CmuxNextWakeups

/// How a group fold's save goes on after its command failed. A fold is this window's look: it shows on the
/// click and never waits for the daemon. A slow save (the reply missed its deadline, so it may still apply)
/// is sent again in the background a few times, with no notice; only a refusal puts the daemon's look back
/// and says why. Leo, 2026-11-03, on "Collapse/Expand Workspace Group did not apply: ... timed out".
public enum SidebarFoldPersist: Equatable, Sendable {
    /// Send the same fold again (after the backoff's next delay).
    case retry
    /// The daemon refused it: drop the fold and report.
    case refused
    /// Still no reply after every attempt: drop the hold quietly; the store's next echo shows what it holds.
    case giveUp

    /// Sends after the first one.
    public static let retries = 4
    /// About 0.5, 1, 2 and 4 s between sends.
    public static var backoff: Backoff { Backoff(initial: .milliseconds(500), maximum: .seconds(4)) }

    /// What follows failed send `attempt` (0 for the first). `mayHaveApplied` is a missed deadline.
    public static func after(attempt: Int, mayHaveApplied: Bool) -> SidebarFoldPersist {
        guard mayHaveApplied else { return .refused }
        return attempt < retries ? .retry : .giveUp
    }
}
