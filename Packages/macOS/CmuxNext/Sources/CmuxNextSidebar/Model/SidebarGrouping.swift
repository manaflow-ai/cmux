public import CmuxNextDesign

/// How the Projects list sorts its rows under headers (`sidebar.groupBy`), with Group by Status's UI-local state:
/// which sections the person folded, and the section the active row keeps.
public nonisolated struct SidebarGrouping: Hashable, Sendable {
    /// `sidebar.groupBy` (none or folder).
    public var by: SidebarGroupBy = .none
    /// Group by Status (Debug `sidebar.groupByStatus`, off by default): it wins over `by` while on.
    public private(set) var byStatus = false
    /// Folded Group by Status headers (never Needs you).
    public var collapsed: Set<SidebarStatusSection> = []
    /// The section the active row keeps while it stays the active row: the row the person is on does not jump to
    /// another section under them. It moves once another row is active (`SidebarModel.settledGrouping`).
    public var held: (row: WorkspaceID, section: SidebarStatusSection)? {
        get { heldRow.map { ($0, heldSection) } }
        set { (heldRow, heldSection) = (newValue?.row, newValue?.section ?? .idle) }
    }
    private var heldRow: WorkspaceID?
    private var heldSection = SidebarStatusSection.idle

    public init() {}

    /// Turns Group by Status on or off. Off forgets its held row and folds, so turning it on again starts fresh.
    public mutating func setByStatus(_ on: Bool) {
        byStatus = on
        if !on { (held, collapsed) = (nil, []) }
    }

    /// Group by Folder: loose rows sit under folder headers.
    public var groupsByFolder: Bool { by == .folder && !byStatus }
    /// Rows sit under headers (folder or status): the list does not reorder by drag.
    public var isGrouped: Bool { by != .none || byStatus }

    /// The section `row` shows under: the held one for the active row, else its own.
    public func section(_ row: SidebarWorkspace) -> SidebarStatusSection {
        if let held, held.row == row.id { return held.section }
        return SidebarStatusSection(row)
    }
}
