public import CmuxNextDesign
import Foundation

/// Group edits and adopt-then-move on the sidebar document
/// (`group.create|update|ungroup`, `adopt` + `move` in one `sidebar.apply`).
extension SidebarDocStore {
    /// The `sidebar.apply` ops of a group intent, or nil for another intent.
    func groupOps(_ intent: SidebarIntent, items: ([WorkspaceID]) -> [String]) -> (ops: [[String: Any]], undoable: Bool)? {
        func update(_ group: GroupID, _ patch: [String: Any]) -> [[String: Any]] {
            [["op": "group.update", "id": item(group: group), "patch": patch]]
        }
        switch intent {
        case .renameGroup(let group, let name): return (update(group, ["name": name]), true)
        case .setGroupColor(let group, let tint): return (update(group, ["color": Self.wire(tint)]), true)
        case .setGroupIcon(let group, let icon): return (update(group, ["icon": icon.map { $0 as Any } ?? NSNull()]), true)
        case .ungroup(let group): return ([["op": "group.ungroup", "id": item(group: group)]], true)
        case .toggleCollapse(.group(let group)):
            // Persisted in the document, so a rebuild keeps it (no undo step).
            guard case .group(_, _, _, let collapsed)? = records.items[item(group: group)]?.body else { return nil }
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

    /// The document item of group `group` (`SidebarDocRecords.groupItem(personal:)`: `itm_g_<id>` for a personal
    /// group, the id itself for a group the document made or an item id); the id as it is when the document holds
    /// no such group (one just created, still in flight). An edit named by the personal id (`grp_…`) was refused
    /// `unknown_item` (#22996).
    func item(group: GroupID) -> String { Self.item(group: group, in: records) }

    static func item(group: GroupID, in records: SidebarDocRecords) -> String {
        records.groupItem(personal: group.rawValue) ?? group.rawValue
    }

    static func wire(_ tint: GroupTint) -> String {
        if case .palette = tint { tint.token.rawValue } else { tint.wire }
    }

    /// The item id the reducer gives a live workspace it adopts (`itm_w_<session>_<workspace>`).
    public static func adoptedID(_ ref: SidebarDocWorkspaceRef) -> String { "itm_w_\(ref.sessionID)_\(ref.workspaceID)" }

    /// The item a personal group migrated or synced into the document lists as (`itm_g_<group id>`, cmux-tui
    /// `group_item_id`); a group the document made keeps its own id in both stores.
    public nonisolated static func groupItemID(personal group: String) -> String { groupItemPrefix + group }

    /// The personal group id of group item `item` (cmux-tui `legacy_group_id`): the id without `itm_g_`, or the
    /// item id itself for a group the document made.
    public nonisolated static func personalGroupID(item: String) -> String {
        item.hasPrefix(groupItemPrefix) ? String(item.dropFirst(groupItemPrefix.count)) : item
    }

    private nonisolated static let groupItemPrefix = "itm_g_"
}

extension SidebarModel {
    /// The id the sidebar shows personal group `group` under: its own, or on the sidebar document its item
    /// (`SidebarDocStore.groupItemID`). Group actions name personal groups; the rows, editors and doc ops name
    /// what the sidebar shows. Its own id when the sidebar shows neither.
    public func groupID(personal group: String) -> GroupID {
        let own = GroupID(group)
        if self.group(own) != nil { return own }
        let item = GroupID(SidebarDocStore.groupItemID(personal: group))
        return self.group(item) != nil ? item : own
    }

    /// The personal group id of the group the active workspace is in (its own id, or its document item's
    /// group id on the sidebar document); nil when the active workspace is in no group.
    public var activeGroupPersonalID: String? {
        guard let active = activeWorkspaceID else { return nil }
        for case let .group(group) in sections.flatMap(\.nodes) where group.workspaces.contains(where: { $0.id == active }) {
            return SidebarDocStore.personalGroupID(item: group.id.rawValue)
        }
        return nil
    }
}
