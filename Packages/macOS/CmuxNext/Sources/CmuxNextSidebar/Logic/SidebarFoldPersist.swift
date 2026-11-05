public import CmuxNextWakeups

/// How a group fold's save goes on after its command failed. A fold is this window's look: it shows on the
/// click and never waits for the daemon. A slow save (the reply missed its deadline, so it may still apply)
/// is sent again in the background a few times, with no notice; only a refusal puts the daemon's look back
/// and says why. Leo, 2026-11-03, on "Collapse/Expand Workspace Group did not apply: ... timed out".
public nonisolated enum SidebarFoldPersist: Equatable, Sendable {
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

nonisolated extension SidebarFoldPersist {
    /// Runs `send`, a save that sets an absolute value (a fold, a workspace's place), so a second send of it is
    /// harmless; a reply that missed its deadline (`mayHaveApplied`) sends it again on the fold's policy and backoff,
    /// with no notice. Throws the refusal at once, or the last missed deadline once the retries are spent (the caller
    /// then re-reads the store). Leo, 2026-11-04, on "Move did not apply: set-personal-workspace: timed out: ...".
    @discardableResult
    public static func resending<Value>(owner: String, backoff: Backoff = backoff, isolation: isolated (any Actor)? = #isolation,
                                        mayHaveApplied: (any Error) -> Bool, _ send: () async throws -> Value) async throws -> Value {
        var backoff = backoff
        for attempt in 0..<retries {
            do { return try await send() } catch {
                guard after(attempt: attempt, mayHaveApplied: mayHaveApplied(error)) == .retry else { throw error }
                // concurrency-allow: Backoff.wait is an async clock sleep (it suspends this task, never blocks a thread)
                try await backoff.wait(owner: owner)
            }
        }
        return try await send() // the last send: a missed deadline now ends it, and the caller re-reads the store
    }
}
