public import CmuxNextDesign
import Foundation

/// Group edits and adopt-then-move on the sidebar document
/// (`group.create|update|ungroup`, `adopt` + `move` in one `sidebar.apply`).
extension SidebarDocStore {
    /// The `sidebar.apply` ops of a group intent, or nil for another intent.
    func groupOps(_ intent: SidebarIntent, items: ([WorkspaceID]) -> [String]) -> (ops: [[String: Any]], undoable: Bool)? {
        func update(_ group: GroupID, _ patch: [String: Any]) -> [[String: Any]] {
            [["op": "group.update", "id": group.rawValue, "patch": patch]]
        }
        switch intent {
        case .renameGroup(let group, let name): return (update(group, ["name": name]), true)
        case .setGroupColor(let group, let tint): return (update(group, ["color": Self.wire(tint)]), true)
        case .setGroupIcon(let group, let icon): return (update(group, ["icon": icon.map { $0 as Any } ?? NSNull()]), true)
        case .ungroup(let group): return ([["op": "group.ungroup", "id": group.rawValue]], true)
        case .toggleCollapse(.group(let group)):
            // Persisted in the document, so a rebuild keeps it (no undo step).
            guard case .group(_, _, _, let collapsed)? = records.items[group.rawValue]?.body else { return nil }
            return (update(group, ["collapsed": !collapsed]), false)
        case let .createGroup(group, name, color, workspaces, anchor, collapsed, _):
            var op: [String: Any] = ["op": "group.create", "id": group.rawValue, "name": SidebarGroup.named(name), "color": color.rawValue,
                                     "items": items(workspaces)]
            if let anchor, let item = items([anchor]).first, let section = records.items[item]?.section {
                op["to"] = ["section": section, "before": item]
            }
            var ops = [op]
            if collapsed { ops += update(group, ["collapsed": true]) }
            return (ops, true)
        default:
            return nil
        }
    }

    static func wire(_ tint: GroupTint) -> String {
        if case .custom = tint { tint.wire } else { tint.token.rawValue }
    }

    /// The item id the reducer gives a live workspace it adopts (`itm_w_<session>_<workspace>`).
    public static func adoptedID(_ ref: SidebarDocWorkspaceRef) -> String { "itm_w_\(ref.sessionID)_\(ref.workspaceID)" }
}
