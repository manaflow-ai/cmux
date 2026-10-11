import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// Personal-mode placement for one window's sidebar: which personal rows
/// a workspace drop writes in the home session, and, with groups placed
/// among the loose workspaces (`personal-mixed-order-v1`), what a group
/// move, a new group or a workspace drop sends so the daemon shows the
/// group where the sidebar put it. The mixed-order math is pure
/// (PersonalSidebar+MixedOrder); this reads the sidebar and the home
/// session's personal state for it.
struct PersonalSidebarPlanner {
    let machines: MachineRegistry

    /// One sidebar workspace as the home session places it: its session and
    /// key, and its public id when the home daemon owns it and takes
    /// `workspace.place` (other sessions' workspaces keep the raw command).
    struct Placement: Sendable {
        var session: String
        var key: WorkspaceKey
        var resource: ResourceID?
    }

    /// The personal rows a workspace drop writes, in order (each index
    /// assumes the previous step applied), then the groups whose
    /// `top_index` becomes `first` (the first moved workspace's new row).
    struct DropPlan: Sendable {
        struct Step: Sendable {
            var workspace: Placement
            var index: Int
            /// Only the moved workspaces change group; the others keep theirs.
            var moves: Bool
        }

        var steps: [Step] = []
        var regroup: [WorkspaceGroupID] = []
        var first: Int?
    }

    func placements(_ ids: [SidebarWorkspaceID]) -> [Placement] {
        let home = machines.local.store
        return ids.compactMap { WindowProfiles.qualified($0.rawValue, machines: machines) }.map { workspace in
            let key = WorkspaceKey(rawValue: workspace.key)
            return Placement(session: workspace.session, key: key, resource: home.personalStateID(session: workspace.session, key: key))
        }
    }

    /// Personal order for `ids` at `position` in a window's `sections`
    /// (taken before the move); nil when the position names no container.
    func dropPlan(_ ids: [SidebarWorkspaceID], at position: DropPosition, in sections: [SidebarRowSection]) -> DropPlan? {
        let scoped = sections.filter { $0.id == position.section }
        guard let local = WorkspaceOrdering.shared.rootIndex(for: position, moving: ids, in: scoped) else { return nil }
        // Each sidebar workspace as `session/key`, the personal order's key.
        var byKey: [String: Placement] = [:]
        let key = { (id: SidebarWorkspaceID) -> String? in
            guard let placement = placements([id]).first else { return nil }
            let qualified = "\(placement.session)/\(placement.key.rawValue)"
            byKey[qualified] = placement
            return qualified
        }
        let moving = ids.compactMap(key)
        let moved = Set(moving)
        let shown = scoped.flatMap(\.workspaces).compactMap { key($0.id) }.filter { !moved.contains($0) }
        let rowed = order.filter { !moved.contains($0) }
        var plan = SidebarMembership.personalPlacements(moving: moving, localIndex: local, shown: shown, rowed: rowed)
        // Mixed order: right before a group the moved rows take its row;
        // groups right before the slot then move to the first moved row.
        let mixed = drop(position, moving: ids, in: scoped.first, keys: moved)
        if let index = mixed?.index {
            plan = moving.enumerated().map { SidebarMembership.PersonalPlacement(key: $1, index: index + $0) }
        }
        return DropPlan(steps: plan.compactMap { step in
            byKey[step.key].map { DropPlan.Step(workspace: $0, index: step.index, moves: moved.contains(step.key)) }
        }, regroup: mixed?.regroup ?? [], first: moving.first.flatMap { key in plan.last(where: { $0.key == key })?.index })
    }

    /// The home session places groups among the loose workspaces.
    var isOn: Bool { machines.local.store.supportsPersonalMixedOrder }

    private var order: [String] { PersonalSidebar.globalOrder(machines.local.store.personal) }

    /// The personal row index of a sidebar workspace (its position in the
    /// personal order of every session), nil without a row.
    func personalRow(_ id: SidebarWorkspaceID) -> Int? {
        guard let workspace = WindowProfiles.qualified(id.rawValue, machines: machines) else { return nil }
        return order.firstIndex(of: "\(workspace.session)/\(workspace.key)")
    }

    /// The home workspace's personal row: a group never shows at or before it.
    var homeRow: Int? {
        let home = machines.local.store
        guard let session = home.registryID, let key = home.workspaces.first(where: { $0.kind == SidebarMapping.homeKind })?.key
        else { return nil }
        return order.firstIndex(of: "\(session)/\(key.rawValue)")
    }

    /// Every personal group in the daemon's group order.
    var groups: [PersonalSidebar.MixedGroup] {
        machines.local.store.personal.groups.sorted { $0.index < $1.index }
            .map { PersonalSidebar.MixedGroup(id: $0.id, topIndex: $0.topIndex) }
    }

    func node(_ node: SidebarNode) -> PersonalSidebar.MixedNode {
        switch node {
        case let .workspace(workspace): .workspace(row: personalRow(workspace.id))
        case let .group(group): .group(WorkspaceGroupID(rawValue: group.id.rawValue))
        }
    }

    /// What to send for `group` where `sections` (the sidebar after the
    /// optimistic edit) show it: its neighbors in its machine section
    /// decide. A group the daemon does not list yet (a new one) counts last
    /// in the group order, where `workspace_group.create` would put it.
    func groupPlacement(of group: CmuxNextSidebar.GroupID, in sections: [SidebarRowSection]) -> PersonalSidebar.GroupPlacement {
        guard let section = sections.first(where: { section in
            section.machine != nil && section.nodes.contains { $0.id == .group(group) }
        }), let index = section.nodes.firstIndex(where: { $0.id == .group(group) }) else { return PersonalSidebar.GroupPlacement() }
        let id = WorkspaceGroupID(rawValue: group.rawValue)
        var groups = self.groups
        if !groups.contains(where: { $0.id == id }) { groups.append(PersonalSidebar.MixedGroup(id: id, topIndex: nil)) }
        let previous = index > 0 ? node(section.nodes[index - 1]) : nil
        let follower = index + 1 < section.nodes.count ? node(section.nodes[index + 1]) : nil
        return PersonalSidebar.groupPlacement(id, previous: previous, follower: follower, groups: groups,
                                              rows: machines.local.store.personal.workspaces.count, home: homeRow, mixed: isOn)
    }

    /// The mixed-order part of a workspace drop at a top-level `position`
    /// of `section` (taken before the move); nil when it does not apply.
    /// `keys` are the moved workspaces as `session/key`.
    func drop(_ position: DropPosition, moving: [SidebarWorkspaceID], in section: SidebarRowSection?,
              keys: Set<String>) -> PersonalSidebar.MixedDrop? {
        guard isOn, position.group == nil, let section, section.machine != nil else { return nil }
        let moved = Set(moving)
        let nodes = section.nodes.compactMap { candidate -> PersonalSidebar.MixedNode? in
            if case let .workspace(workspace) = candidate, moved.contains(workspace.id) { return nil }
            return node(candidate)
        }
        return PersonalSidebar.mixedDrop(nodes: nodes, slot: position.index, groups: groups, rows: order, moving: keys)
    }
}
