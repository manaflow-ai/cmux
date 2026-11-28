import Foundation

nonisolated extension SidebarSection {
    /// True while any row is saved or a placeholder, not live daemon data
    /// (`SidebarRowState`). A row being created is not provisional: it is
    /// drawn in its final look and opens like any new row.
    public var hasProvisionalRows: Bool { workspaces.contains { $0.rowState == .stale || $0.rowState == .placeholder } }
}
