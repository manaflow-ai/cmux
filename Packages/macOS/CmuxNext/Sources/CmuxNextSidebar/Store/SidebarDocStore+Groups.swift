public import CmuxNextDesign
import Foundation

/// Group edits and adopt-then-move on the sidebar document
/// (`group.create|update|ungroup`, `adopt` + `move` in one `sidebar.apply`).
extension SidebarDocStore {
    /// The `sidebar.apply` ops of a group intent, or nil for another intent. `room`: the window's space, stored on a
    /// new group (`profile`) so it lists only there while no workspace of it lists (spaces.md).
    func groupOps(_ intent: SidebarIntent, room: String? = nil, items: ([WorkspaceID]) -> [String]) -> (ops: [[String: Any]], undoable: Bool)? {
        func update(_ group: GroupID, _ patch: [String: Any]) -> [[String: Any]] {
            [["op": "group.update", "id": item(group: group), "patch": patch]]
        }
        switch intent {
        case .renameGroup(let group, let name): return (update(group, ["name": name]), true)
        case .setGroupColor(let group, let tint): return (update(group, ["color": Self.wire(tint)]), true)
        case .setGroupIcon(let group, let icon): return (update(group, ["icon": icon.map { $0 as Any } ?? NSNull()]), true)
        case .ungroup(let group): return ([["op": "group.ungroup", "id": item(group: group)]], true)
        case .toggleCollapse(.group(let group)):
            // Persisted in the document, so a rebuild keeps it (no undo step). The shown records: a group created
            // or folded a moment ago, still in flight, toggles from what it shows (#26382).
            guard case .group(_, _, _, let collapsed)? = shownRecords.items[item(group: group)]?.body else { return nil }
            return (update(group, ["collapsed": !collapsed]), false)
        case let .createGroup(group, name, color, workspaces, anchor, collapsed, _):
            var op: [String: Any] = ["op": "group.create", "id": group.rawValue, "name": SidebarGroup.named(name), "color": color.wire,
                                     "items": items(workspaces)]
            if let room { op["profile"] = room }
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

    /// Stores how group `group` lists its workspaces (`extra.sort`; manual removes it), one undo step. The stored
    /// order stays: `arrange` lists the members in the sort, and Manual lists the stored order again. A change
    /// refused at once throws its message (`workspaceGroup.setSort` reports it).
    public func setGroupSort(_ group: GroupID, _ sort: SidebarGroupSort) throws(SidebarDocSendRefusal) {
        try sendChecked(ops: [["op": "group.update", "id": item(group: group), "patch": ["sort": sort.rawValue]]], title: GroupEditorStrings.sortUndo)
    }

    /// Group `group`'s own Chats per Project (nil: the global setting; 0: All), from its right-click menu (Leo
    /// 2026-11-10: "a per-project override in the right-click menu"). Undoable, as a sort is.
    public func setGroupRowLimit(_ group: GroupID, _ cap: Int?) throws(SidebarDocSendRefusal) {
        let value: Any = cap.map { $0 == 0 ? "all" as Any : $0 as Any } ?? NSNull()
        try sendChecked(ops: [["op": "group.update", "id": item(group: group), "patch": ["row_limit": value]]],
                        title: GroupEditorStrings.rowLimitUndo)
    }

    /// How far group `group`'s "Show N more" revealed (0: folded to its cap), so the project opens as it was left.
    /// View state the window already shows: no undo entry and no rebuild, as a fold (`setGroupCollapsed`).
    public func setGroupRevealed(_ group: GroupID, _ revealed: Int) {
        let ops: [[String: Any]] = [["op": "group.update", "id": item(group: group), "patch": ["revealed": revealed > 0 ? revealed as Any : NSNull()]]]
        send(ops: ops, title: Self.moveTitle, undoable: false)
    }

    /// Group `group`'s own Chats per Project as the sidebar last drew it (`SidebarGroup.rowLimit`; 0 is All): nil
    /// when it follows the setting.
    public func groupRowLimit(_ group: GroupID) -> Int? { projectionCache?.projection.groupRowLimits[item(group: group)] }

    /// How group `group` lists its workspaces now: manual when the document holds no sort for it.
    public func groupSort(_ group: GroupID) -> SidebarGroupSort { records.items[item(group: group)]?.sort ?? .manual }

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

    /// The group shown for group target `target` that the personal store may not hold yet (one made a moment ago,
    /// before its create's echo), with its personal id: by the sidebar's id, else by the daemon's id once the daemon
    /// made it under its own (`created`: a sidebar-made id's daemon id). nil when no shown group matches (a stale target).
    public func shownGroup(target: String, created: (String) -> String?) -> (group: SidebarGroup, personalID: String)? {
        let landed = created(SidebarDocStore.personalGroupID(item: target))
        for case let candidate? in [target, landed, landed.map(SidebarDocStore.groupItemID(personal:))] {
            if let group = group(GroupID(candidate)) { return (group, landed ?? SidebarDocStore.personalGroupID(item: candidate)) }
        }
        return nil
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
