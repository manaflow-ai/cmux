import Foundation

nonisolated extension SidebarSection {
    /// True while any row is saved or a placeholder, not live daemon data
    /// (`SidebarRowState`).
    public var hasProvisionalRows: Bool { workspaces.contains { $0.rowState != .live } }
}
