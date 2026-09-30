import CmuxNextBridge
import CmuxNextSidebar

/// A sidebar reorder as daemon commands. The sidebar names a slot in one
/// window's filtered tree (`DropPosition`, counted after the moved rows are
/// removed); the daemon keeps one durable workspace order per machine that
/// groups partition (cmux-tui/spec/commands.md, `move-workspace-to-group`).
enum WorkspaceMovePlan {
    /// One workspace in the daemon's durable order.
    struct Entry: Hashable {
        var id: String
        var group: String?
    }

    enum Command: Hashable {
        /// `move-workspace`: insertion `index` in the durable order.
        case move(id: String, index: Int)
        /// `move-workspace-to-group`: final `index` among the destination
        /// section's other members (`group` nil is the ungrouped section).
        case place(id: String, group: String?, index: Int)
    }

    /// The commands, in order, that put `moving` at `position`. `window` is
    /// the window's sidebar before the move; `daemon` is the machine's
    /// durable order and `groupOrder` its group ids in sidebar order. Nil
    /// when the position names nothing.
    static func commands(for position: DropPosition, moving: [SidebarWorkspaceID], window: [SidebarRowSection],
                         daemon: [Entry], groupOrder: [String]) -> [Command]? {
        let scoped = window.filter { $0.id == position.section }
        guard let local = WorkspaceOrdering.rootIndex(for: position, moving: moving, in: scoped) else { return nil }
        let moved = Set(moving.map(\.rawValue))
        let localOrder = scoped.flatMap(\.workspaces).map(\.id.rawValue).filter { !moved.contains($0) }
        let known = Set(groupOrder)
        let ungrouped = daemon.filter { $0.group.map { !known.contains($0) } ?? true }.map(\.id)
        let sidebarOrder = ungrouped + groupOrder.flatMap { group in daemon.filter { $0.group == group }.map(\.id) }
        let global = sidebarOrder.filter { !moved.contains($0) }
        let root = SidebarMembership.globalIndex(localIndex: local, local: localOrder, global: global)
        return moving.enumerated().map { offset, id in
            if let group = position.group { return .place(id: id.rawValue, group: group.rawValue, index: root + offset) }
            return .move(id: id.rawValue, index: root + offset)
        }
    }
}
