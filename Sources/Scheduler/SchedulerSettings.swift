import Foundation

struct SchedulerSettings {
    /// UserDefaults key controlling global git worktree isolation for scheduled tasks.
    /// When `true`, tasks with a `workingDirectory` pointing to a git repo will run
    /// in a temporary worktree. Individual tasks can override this via `useWorktree`.
    static let worktreeIsolationKey = "schedulerWorktreeIsolation"

    /// Returns `true` when global worktree isolation is enabled (default: false).
    static var isWorktreeIsolationEnabled: Bool {
        UserDefaults.standard.bool(forKey: worktreeIsolationKey)
    }
}
