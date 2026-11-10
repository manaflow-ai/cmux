/// SIDEBAR ROW CHANGE stage 2: one loose workspace row gone from a window's list or new in it, as the INPUT of the
/// model and the list (Chromium's `TabStripModelChange`: the strip gets the change with its index and lays out from
/// it; it never finds the change by a compare of the old tabs and the new ones). `SidebarModel.setSections` took the
/// whole new list and found the one row by reading every listed row several times (826 workspaces: 1688 rows read per
/// close after stage 1).
///
/// `section` and `node` name the row's place in the rows the caller gave to the last `SidebarModel.setSections`; the
/// model takes a change only while its own rows have the same places (no document arrangement, no hidden node).
public nonisolated enum SidebarLooseRowChange: Sendable, Equatable {
    /// The loose row of workspace `id`, node `node` of `section`, left the list. Every other row stays.
    case removed(WorkspaceID, section: SectionID, node: Int)
    /// `workspace`'s loose row is new at node `node` of `section`. Every other row stays.
    case added(SidebarWorkspace, section: SectionID, node: Int)
}

extension SidebarModel {
    /// Whether the model takes a one-row change now. The red commit: never.
    public var takesRowChanges: Bool { false }

    /// Shows `change` as `setSections` shows the same rows without the row, or with it. False, with nothing changed,
    /// when the model can not prove that: the caller then sets the sections. The red commit: always false.
    @discardableResult
    public func apply(_ change: SidebarLooseRowChange) -> Bool { false }
}
