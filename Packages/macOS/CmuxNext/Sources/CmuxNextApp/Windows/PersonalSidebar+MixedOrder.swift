import CmuxNextDaemon

/// Groups placed among the loose personal workspaces
/// (`personal-mixed-order-v1`, cmux-tui `state/personal_order.rs`).
extension PersonalSidebar {
    /// One node of a sidebar section, as the personal order sees it: a
    /// loose workspace by its personal row index (nil without a row), or a
    /// group.
    nonisolated enum MixedNode: Hashable, Sendable {
        case workspace(row: Int?)
        case group(WorkspaceGroupID)
    }

    /// A personal group in the daemon's group order.
    nonisolated struct MixedGroup: Hashable, Sendable {
        var id: WorkspaceGroupID
        var topIndex: Int?
    }

    /// What to send so a group shows where the sidebar put it: its
    /// `top_index`, and an insertion index for `workspace_group.move` into
    /// the group order (counted with the group itself; nil: no move).
    nonisolated struct GroupPlacement: Hashable, Sendable {
        var topIndex: FieldUpdate<Int> = .unchanged
        var move: Int?
    }

    /// Where a workspace drop at a top-level slot goes in the mixed order.
    nonisolated struct MixedDrop: Hashable, Sendable {
        /// The personal index for the first moved workspace when the slot
        /// is right before a group; nil: the slot's next loose workspace
        /// decides (`SidebarMembership.personalPlacements`).
        var index: Int?
        /// The groups right before the slot: each gets the first moved
        /// workspace's new index as its `top_index`, so it stays before it.
        var regroup: [WorkspaceGroupID] = []
    }

    /// Where `group` goes once the sidebar shows it between `previous` and
    /// `follower` (nodes of its section, the group left out). `groups` is
    /// the daemon's group order, with `group` in it; `rows` counts every
    /// personal row; `home` is the home workspace's row.
    ///
    /// Mixed order: before a loose row, the group takes that row's index
    /// (never at or before `home`: home.pinned_first, so the next row; a
    /// workspace without a row cannot be named, so the end), and comes
    /// after the other groups at that place. Before another group it takes
    /// that group's place and moves right before it in group order. At the
    /// end it clears its place and follows the other end groups.
    /// Without the mixed order only the group order moves: right before the
    /// next group, else right after the previous one.
    nonisolated static func groupPlacement(_ group: WorkspaceGroupID, previous: MixedNode?, follower: MixedNode?, groups: [MixedGroup],
                               rows: Int, home: Int?, mixed: Bool) -> GroupPlacement {
        guard let old = groups.firstIndex(where: { $0.id == group }) else { return GroupPlacement() }
        let position = { (id: WorkspaceGroupID) in groups.firstIndex { $0.id == id } }
        // An insertion index into `groups`, or nil when it leaves the group where it is.
        let move = { (insertion: Int) -> Int? in (insertion > old ? insertion - 1 : insertion) == old ? nil : insertion }
        if case let .group(next)? = follower, let target = position(next) {
            let top = mixed ? groups[target].topIndex.flatMap { $0 < rows ? $0 : nil } : nil
            return GroupPlacement(topIndex: mixed ? (top.map { .set($0) } ?? .clear) : .unchanged, move: move(target))
        }
        guard mixed else {
            guard case let .group(before)? = previous, let target = position(before) else { return GroupPlacement() }
            return GroupPlacement(move: move(target + 1))
        }
        var top: Int?
        if case let .workspace(row)? = follower, let row {
            top = max(row, home.map { $0 + 1 } ?? 0)
        }
        // The groups at the same place show first: this one goes after them.
        let place = { (candidate: MixedGroup) in candidate.topIndex.flatMap { $0 < rows ? $0 : nil } }
        let last = groups.indices.last(where: { $0 != old && place(groups[$0]) == top })
        return GroupPlacement(topIndex: top.map { .set($0) } ?? .clear, move: last.flatMap { $0 > old ? move($0 + 1) : nil })
    }

    /// The personal index (counted without `moving`) that puts a workspace
    /// right before a group whose `top_index` is `top`: the index of the
    /// first row at or after `top` that stays, else the end.
    nonisolated static func anchorIndex(top: Int?, rows: [String], moving: Set<String>) -> Int {
        let staying = rows.filter { !moving.contains($0) }
        guard let top, top < rows.count, let anchor = rows[top...].first(where: { !moving.contains($0) }),
              let index = staying.firstIndex(of: anchor) else { return staying.count }
        return index
    }

    /// A workspace drop at top-level `slot` of `nodes` (the section with
    /// the moved workspaces left out). Right before a group the moved
    /// workspaces take the group's row (`anchorIndex`); the daemon keeps the
    /// group at its place among the other rows, so it then shows after them.
    /// Right after a run of groups, those groups take the moved workspace's
    /// new row afterwards, or they would show after it.
    nonisolated static func mixedDrop(nodes: [MixedNode], slot: Int, groups: [MixedGroup], rows: [String], moving: Set<String>) -> MixedDrop {
        let slot = min(max(slot, 0), nodes.count)
        var drop = MixedDrop()
        if slot < nodes.count, case let .group(next) = nodes[slot] {
            drop.index = anchorIndex(top: groups.first { $0.id == next }?.topIndex, rows: rows, moving: moving)
        }
        for node in nodes[..<slot].reversed() {
            guard case let .group(id) = node else { break }
            drop.regroup.insert(id, at: 0)
        }
        return drop
    }
}
