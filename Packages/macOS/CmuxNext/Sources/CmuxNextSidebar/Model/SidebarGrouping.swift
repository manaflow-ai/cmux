public import CmuxNextDesign

/// How the Projects list buckets its rows (`sidebar.groupBy`), with Group by Status's UI-local
/// state: which buckets the person folded, and the bucket the active row keeps.
public nonisolated struct SidebarGrouping: Hashable, Sendable {
    /// `sidebar.groupBy` (none or folder).
    public var by: SidebarGroupBy = .none
    /// Group by Status (Debug `sidebar.groupByStatus`): it wins over `by` while on.
    public var byStatus = false
    /// Folded Group by Status headers (never Needs you).
    public var collapsed: Set<SidebarStatusBucket> = []
    /// Group by Status's elbow children (Debug `sidebar.statusElbow`): a child agent session's
    /// row (`SidebarWorkspace.parentWorkspace`) sits directly under its parent row, in the parent's
    /// bucket, drawn with the CLI connector `⎿` (`SidebarLayout+Status`). Off: no connector.
    public var elbowsChildren = false
    /// The bucket the active row keeps while it stays the active row: the row the person is on
    /// does not jump to another section under them. It moves once another row is active.
    public var held: (row: WorkspaceID, bucket: SidebarStatusBucket)? {
        get { heldRow.map { ($0, heldBucket) } }
        set { (heldRow, heldBucket) = (newValue?.row, newValue?.bucket ?? .noAgent) }
    }
    private var heldRow: WorkspaceID?
    private var heldBucket = SidebarStatusBucket.noAgent

    public init() {}

    /// The `sidebar.*` preferences it follows, with Group by Status's Debug toggles laid over
    /// them (`SidebarSectionsPreferences.withStatusDebugToggles`). Turning Group by Status off
    /// forgets its held row and folds, so turning it on again starts fresh.
    public mutating func follow(_ preferences: SidebarSectionsPreferences) {
        (by, byStatus, elbowsChildren) = (preferences.groupBy, preferences.groupsByStatus, preferences.statusElbow)
        if !byStatus { (held, collapsed) = (nil, []) }
    }

    /// Group by Folder: loose rows sit under folder headers.
    public var groupsByFolder: Bool { by == .folder && !byStatus }
    /// Rows sit under headers (folder or status): the list does not reorder by drag.
    public var isGrouped: Bool { by != .none || byStatus }

    /// The bucket `row` shows under (`SidebarModel.settledGrouping` drops a hold the active row lost).
    public func bucket(_ row: SidebarWorkspace) -> SidebarStatusBucket {
        if let held, held.row == row.id { return held.bucket }
        return SidebarStatusBucket(row)
    }
}
