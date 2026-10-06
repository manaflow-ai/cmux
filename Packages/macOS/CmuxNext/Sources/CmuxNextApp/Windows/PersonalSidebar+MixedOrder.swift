import CmuxNextDaemon

/// Groups placed among the loose personal workspaces
/// (`personal-mixed-order-v1`, cmux-tui `state/personal_order.rs`).
extension PersonalSidebar {
    /// One node of a sidebar section, as the personal order sees it: a
    /// loose workspace by its personal row index (nil without a row), or a
    /// group.
    enum MixedNode: Hashable {
        case workspace(row: Int?)
        case group(WorkspaceGroupID)
    }

    /// A personal group in the daemon's group order.
    struct MixedGroup: Hashable {
        var id: WorkspaceGroupID
        var topIndex: Int?
    }

    /// What to send so a group shows where the sidebar put it: its
    /// `top_index`, and an insertion index for `workspace_group.move` into
    /// the group order (counted with the group itself; nil: no move).
    struct GroupPlacement: Hashable {
        var topIndex: FieldUpdate<Int> = .unchanged
        var move: Int?
    }

    /// Where a workspace drop at a top-level slot goes in the mixed order.
    struct MixedDrop: Hashable {
        /// The personal index for the first moved workspace when the slot
        /// is right before a group; nil: the slot's next loose workspace
        /// decides (`SidebarMembership.personalPlacements`).
        var index: Int?
        /// The groups right before the slot: each gets the first moved
        /// workspace's new index as its `top_index`, so it stays before it.
        var regroup: [WorkspaceGroupID] = []
    }

    static func groupPlacement(_ group: WorkspaceGroupID, previous: MixedNode?, follower: MixedNode?, groups: [MixedGroup],
                               rows: Int, home: Int?, mixed: Bool) -> GroupPlacement {
        GroupPlacement()
    }

    static func anchorIndex(top: Int?, rows: [String], moving: Set<String>) -> Int {
        rows.count
    }

    static func mixedDrop(nodes: [MixedNode], slot: Int, groups: [MixedGroup], rows: [String], moving: Set<String>) -> MixedDrop {
        MixedDrop()
    }
}
