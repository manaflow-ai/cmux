public import CmuxNextDesign

/// How the Projects list buckets its rows (`sidebar.groupBy`), with Group by Status's UI-local
/// state: which buckets the person folded, and the bucket the active row keeps.
public nonisolated struct SidebarGrouping: Hashable, Sendable {
    public var by: SidebarGroupBy = .none
    /// Folded Group by Status headers (never Needs you).
    public var collapsed: Set<SidebarStatusBucket> = []
    /// The bucket the active row keeps while it stays the active row: the row the person is on
    /// does not jump to another section under them. It moves once another row is active.
    public var held: (row: WorkspaceID, bucket: SidebarStatusBucket)? {
        get { heldRow.map { ($0, heldBucket) } }
        set { (heldRow, heldBucket) = (newValue?.row, newValue?.bucket ?? .noAgent) }
    }
    private var heldRow: WorkspaceID?
    private var heldBucket = SidebarStatusBucket.noAgent

    public init() {}

    /// The bucket `row` shows under (`SidebarModel.settledGrouping` drops a hold the active row lost).
    public func bucket(_ row: SidebarWorkspace) -> SidebarStatusBucket {
        if let held, held.row == row.id { return held.bucket }
        return SidebarStatusBucket(row)
    }
}
