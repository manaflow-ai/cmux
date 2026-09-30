import CmuxNextBridge
import CmuxNextSidebar

/// A sidebar reorder as daemon commands. The sidebar names a slot in one
/// window's filtered tree (`DropPosition`, counted after the moved rows are
/// removed); the daemon keeps one durable workspace order per machine that
/// groups partition, and lists a group's members (and the ungrouped ones) in
/// that order (cmux-tui/spec/commands.md, `move-workspace-to-group`).
///
/// Every move is one `move-workspace-to-group` into the destination section
/// (nil = ungrouped), whose index is the final position among that section's
/// other members: the same "after removal" counting the sidebar uses, and it
/// also ungroups a workspace dragged out of a group. The slot maps to the
/// daemon by neighbor: before the window's row that follows it, else after
/// the window's last row there, so workspaces of other windows keep theirs.
enum WorkspaceMovePlan {
    /// One workspace in the daemon's durable order.
    struct Entry: Hashable {
        var id: String
        var group: String?
    }

    enum Command: Hashable {
        /// `move-workspace`: insertion `index` in the durable order, counted
        /// with the moved workspace still in place (daemons without
        /// `workspace-groups-v1`, which have no groups).
        case move(id: String, index: Int)
        /// `move-workspace-to-group`: final `index` among the destination
        /// section's other members (`group` nil is the ungrouped section).
        case place(id: String, group: String?, index: Int)
    }

    /// Where the first moved workspace goes among the destination's members.
    private enum Anchor {
        case before(String)
        case after(String)
        case end
    }

    /// The commands, in order, that put `moving` (tree order) at `position`.
    /// `window` is the window's sidebar before the move; `daemon` is the
    /// machine's durable order. With `groups` false the daemon has no
    /// groups and gets `move-workspace`. Nil when the position names nothing.
    static func commands(for position: DropPosition, moving: [SidebarWorkspaceID], window: [SidebarRowSection],
                         daemon: [Entry], groups: Bool = true) -> [Command]? {
        guard let section = window.first(where: { $0.id == position.section }),
              let anchor = anchor(for: position, moving: Set(moving.map(\.rawValue)), in: section)
        else { return nil }
        let group = position.group?.rawValue
        guard groups || group == nil else { return nil }
        var order = daemon
        var commands: [Command] = []
        var previous: String?
        for id in moving.map(\.rawValue) {
            guard let old = order.firstIndex(where: { $0.id == id }) else { return nil }
            let others = order.filter { $0.group == group && $0.id != id }.map(\.id)
            let index: Int
            switch previous.map(Anchor.after) ?? anchor {
            case .before(let next): index = others.firstIndex(of: next) ?? others.count
            case .after(let last): index = others.firstIndex(of: last).map { $0 + 1 } ?? others.count
            case .end: index = others.count
            }
            let new = place(&order, from: old, group: group, index: index)
            commands.append(groups ? .place(id: id, group: group, index: index) : .move(id: id, index: new > old ? new + 1 : new))
            previous = id
        }
        return commands
    }

    /// A slot the sidebar resolved with `moving`'s rows still shown (a tab
    /// dragged onto a gap, `SidebarTabDrop.newWorkspace`) as the slot
    /// `commands` takes, counted after those rows are removed.
    static func excluding(_ moving: Set<String>, from position: DropPosition, in window: [SidebarRowSection]) -> DropPosition {
        position
    }

    /// The window's neighbor of the slot: its row after the slot, else its
    /// last row in the destination, else the destination's end.
    private static func anchor(for position: DropPosition, moving: Set<String>, in section: SidebarRowSection) -> Anchor? {
        let local: [String]
        let slot: Int
        if let group = position.group {
            let node = section.nodes.lazy.compactMap { node -> SidebarGroup? in
                if case let .group(value) = node, value.id == group { return value }
                return nil
            }.first
            guard let node else { return nil }
            local = node.workspaces.map(\.id.rawValue).filter { !moving.contains($0) }
            slot = min(max(position.index, 0), local.count)
        } else {
            // Top-level slots count group headers too; ungrouped rows are
            // the only ones in the ungrouped section.
            let nodes = section.nodes.filter { node in
                if case let .workspace(workspace) = node { return !moving.contains(workspace.id.rawValue) }
                return true
            }
            local = nodes.compactMap { node in
                if case let .workspace(workspace) = node { return workspace.id.rawValue }
                return nil
            }
            slot = nodes.prefix(max(position.index, 0)).count { node in
                if case .workspace = node { return true }
                return false
            }
        }
        if slot < local.count { return .before(local[slot]) }
        return local.last.map(Anchor.after) ?? .end
    }

    /// Applies one `move-workspace-to-group` as cmux-tui does
    /// (presentation.rs `move_workspace_to_group`); returns the new index.
    private static func place(_ order: inout [Entry], from old: Int, group: String?, index: Int) -> Int {
        let remaining = order.indices.filter { $0 != old }
        let members = remaining.filter { order[$0].group == group }
        let position = { (target: Int) in remaining.firstIndex(of: target) ?? old }
        var new = old
        if let last = members.last {
            new = index < members.count ? position(members[index]) : position(last) + 1
        }
        new = min(new, order.count - 1)
        var entry = order.remove(at: old)
        entry.group = group
        order.insert(entry, at: new)
        return new
    }
}
