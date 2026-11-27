public import Foundation

extension AcpmuxEnvironment {
    /// The biggest worktree cleanup reply read: each worktree's line carries its facts, and a
    /// machine with hundreds of worktrees passes the client's 1 MiB default.
    nonisolated static let worktreeCareReplyLimit = 16 << 20

    /// `_acpmux/worktree/report` (cmux-tui acpmux `server/worktrees.rs`): a pass that only decides
    /// and measures, as `{report, last}` JSON, where `last` is the last pass that acted since the
    /// daemon started (null before one). Only this machine's clients get it. It never starts a
    /// daemon. Throws the daemon's refusal (``AcpmuxRPCError``: a pass already running), or a
    /// failure to reach it.
    @concurrent public nonisolated func worktreeCareReport(deadline: Duration = .seconds(300)) async throws -> Data {
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/worktree/report",
                                                       deadline: deadline, detailed: true, limit: Self.worktreeCareReplyLimit)
        return try JSONSerialization.data(withJSONObject: result)
    }

    /// `_acpmux/worktree/clean {}`: a pass that acts on every worktree now, whatever
    /// `worktrees.autoCleanup` says (the machine's Clean up now), as its report JSON. It never
    /// deletes work that lives only here: that work is archived first, and
    /// `_acpmux/worktree/restore` brings a worktree back.
    @concurrent public nonisolated func worktreeCareClean(deadline: Duration = .seconds(1800)) async throws -> Data {
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/worktree/clean",
                                                       deadline: deadline, detailed: true, limit: Self.worktreeCareReplyLimit)
        return try JSONSerialization.data(withJSONObject: result)
    }
}
