internal import CmuxMobileRPC

/// Immutable projection consumed by the lazy changes list.
struct ChangesScreenSnapshot: Sendable, Equatable {
    /// Whether the first summary request is active.
    let isLoadingSummary: Bool
    /// Summary failure, when present.
    let error: ChangesErrorSnapshot?
    /// Aggregate totals from the host.
    let totals: MobileChangesTotals?
    /// Current file snapshots in host order.
    let files: [DiffFileSnapshot]
    /// Number of current patch digests marked viewed.
    let viewedCount: Int
    /// Whether whitespace changes are ignored.
    let ignoresWhitespace: Bool

    /// Creates a list projection.
    init(
        isLoadingSummary: Bool,
        error: ChangesErrorSnapshot?,
        totals: MobileChangesTotals?,
        files: [DiffFileSnapshot],
        viewedCount: Int,
        ignoresWhitespace: Bool
    ) {
        self.isLoadingSummary = isLoadingSummary
        self.error = error
        self.totals = totals
        self.files = files
        self.viewedCount = viewedCount
        self.ignoresWhitespace = ignoresWhitespace
    }
}
