import Foundation

/// The parts of a worktree cleanup pass's report this Mac's storage card shows (cmux-tui
/// `cmux_worktree_care::pass::Report`, with acpmux's `autoCleanup` and `at`). The card only reads
/// it; every decision is the daemon's.
nonisolated struct WorktreeCareReport: Decodable, Equatable, Sendable {
    /// The disk the pass looked at (the home folder's), nil when the daemon could not read it.
    struct Disk: Decodable, Equatable, Sendable {
        let total: UInt64
        /// What an unprivileged user may still write.
        let available: UInt64
    }

    struct Item: Decodable, Equatable, Sendable {
        struct Verdict: Decodable, Equatable, Sendable {
            /// `keep`, `trim`, `reclaim` or `archive`.
            let action: String
        }

        let verdict: Verdict
    }

    let disk: Disk?
    /// A pass that acted (Clean up now), not a measuring one.
    let applied: Bool
    let items: [Item]
    /// The bytes the pass freed (a pass that acted).
    let freed: UInt64
    /// The bytes acting on every worktree not kept would free (a measuring pass).
    let reclaimable: UInt64
    /// Whether passes run by themselves (`worktrees.autoCleanup`).
    let autoCleanup: Bool?
    /// When the pass ended, in milliseconds since 1970.
    let at: Double?

    /// The worktrees the pass leaves as they are.
    var kept: Int { items.filter { $0.verdict.action == "keep" }.count }
    /// The worktrees the pass trims, reclaims or archives.
    var toClean: Int { items.count - kept }
    var date: Date? { at.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// `_acpmux/worktree/report`'s answer: a measuring pass now, and the last pass that acted since
/// the daemon started (nil before one).
nonisolated struct WorktreeCareReportReply: Decodable, Equatable, Sendable {
    let report: WorktreeCareReport
    let last: WorktreeCareReport?
}
