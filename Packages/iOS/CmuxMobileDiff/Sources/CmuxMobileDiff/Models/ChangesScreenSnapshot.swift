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
    /// Current chain-compressed file tree.
    let fileTree: [FileTreeNode]
    /// Number of current patch digests marked viewed.
    let viewedCount: Int
    /// Whether whitespace changes are ignored.
    let ignoresWhitespace: Bool
    /// Active Git comparison strategy.
    let baseKind: MobileChangesBaseKind

    /// Creates a list projection.
    init(
        isLoadingSummary: Bool,
        error: ChangesErrorSnapshot?,
        totals: MobileChangesTotals?,
        files: [DiffFileSnapshot],
        fileTree: [FileTreeNode],
        viewedCount: Int,
        ignoresWhitespace: Bool,
        baseKind: MobileChangesBaseKind
    ) {
        self.isLoadingSummary = isLoadingSummary
        self.error = error
        self.totals = totals
        self.files = files
        self.fileTree = fileTree
        self.viewedCount = viewedCount
        self.ignoresWhitespace = ignoresWhitespace
        self.baseKind = baseKind
    }
}
