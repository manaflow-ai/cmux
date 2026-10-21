import Foundation

nonisolated extension SidebarSection {
    /// True while any row is saved or a placeholder, not live daemon data
    /// (`SidebarRowState`). A row being created is not provisional: it is
    /// drawn in its final look and opens like any new row.
    /// Walks the nodes in place (no `workspaces` array): it runs on every render.
    public var hasProvisionalRows: Bool {
        func provisional(_ ws: SidebarWorkspace) -> Bool { ws.rowState == .stale || ws.rowState == .placeholder }
        return nodes.contains { node in
            switch node {
            case let .workspace(ws): provisional(ws)
            case let .group(group): group.workspaces.contains(where: provisional)
            case .item: false
            }
        }
    }
}
