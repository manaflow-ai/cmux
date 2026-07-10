import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceOptimisticOrderTests {
    private func workspace(
        _ id: String,
        name: String? = nil,
        groupID: String? = nil,
        unread: Bool = false,
        pinned: Bool = false
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: name ?? id,
            isPinned: pinned,
            groupID: groupID.map(MobileWorkspaceGroupPreview.ID.init(rawValue:)),
            hasUnread: unread,
            terminals: []
        )
    }

    private func group(_ id: String, collapsed: Bool, pinned: Bool = false) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: .init(rawValue: id),
            name: id,
            isCollapsed: collapsed,
            isPinned: pinned,
            anchorWorkspaceID: "anchor"
        )
    }

    private func snapshots(_ ids: [String]) -> [MobileWorkspacePreview] {
        ids.map { workspace($0) }
    }

    private func order(_ ids: [String]) -> MobileWorkspaceOptimisticOrder {
        MobileWorkspaceOptimisticOrder(workspaces: snapshots(ids))
    }

    @Test func threeMoveChainKeepsEveryIntermediateUntilDisplayedOrderArrives() {
        let a0 = snapshots(["a", "b", "c", "d"])
        let o1 = snapshots(["b", "a", "c", "d"])
        let o2 = snapshots(["b", "c", "a", "d"])
        let o3 = snapshots(["b", "c", "d", "a"])
        var state = MobileWorkspaceOptimisticOrderReconciler(
            optimisticOrder: MobileWorkspaceOptimisticOrder(workspaces: o3),
            pendingBases: [a0, o1, o2].map { MobileWorkspaceOptimisticOrder(workspaces: $0) }
        )

        state = state.reconciling(authoritative: o1)
        #expect(state.optimisticOrder == MobileWorkspaceOptimisticOrder(workspaces: o3))
        #expect(state.pendingBases == [order(["b", "a", "c", "d"]), order(["b", "c", "a", "d"])])

        state = state.reconciling(authoritative: o2)
        #expect(state.optimisticOrder == MobileWorkspaceOptimisticOrder(workspaces: o3))
        #expect(state.pendingBases == [order(["b", "c", "a", "d"])])

        state = state.reconciling(authoritative: o3)
        #expect(state.optimisticOrder == nil)
        #expect(state.pendingBases.isEmpty)
    }

    @Test func outOfOrderOlderSnapshotSupersedesAfterLaterIntermediate() {
        let o1 = snapshots(["b", "a", "c", "d"])
        let o2 = snapshots(["b", "c", "a", "d"])
        var state = MobileWorkspaceOptimisticOrderReconciler(
            optimisticOrder: order(["b", "c", "d", "a"]),
            pendingBases: [order(["a", "b", "c", "d"]), order(["b", "a", "c", "d"]), order(["b", "c", "a", "d"])]
        )

        state = state.reconciling(authoritative: o2)
        #expect(state.pendingBases == [order(["b", "c", "a", "d"])])
        state = state.reconciling(authoritative: o1)
        #expect(state.optimisticOrder == nil)
        #expect(state.pendingBases.isEmpty)
    }

    @Test func failureMidChainRollsBackAndClearsEveryPendingBase() {
        let state = MobileWorkspaceOptimisticOrderReconciler(
            optimisticOrder: order(["b", "c", "a"]),
            pendingBases: [order(["a", "b", "c"]), order(["b", "a", "c"])]
        ).reconciling(authoritative: snapshots(["b", "a", "c"]), moveDidFail: true)

        #expect(state.optimisticOrder == nil)
        #expect(state.pendingBases.isEmpty)
    }

    @Test func liveContentFlowsThroughWhileOrderAndMembershipAreHeld() {
        let optimistic = MobileWorkspaceOptimisticOrder(workspaces: [
            workspace("b"), workspace("a", groupID: "g"),
        ])
        let authoritative = [
            workspace("a", name: "Updated title", unread: true), workspace("b"),
        ]
        let displayed = optimistic.materializedWorkspaces(from: authoritative)

        #expect(displayed.map(\.id.rawValue) == ["b", "a"])
        #expect(displayed[1].name == "Updated title")
        #expect(displayed[1].hasUnread)
        #expect(displayed[1].groupID == "g")
    }

    @Test func collapseChangeRematerializesGroupedItemsWhileOrderIsHeld() {
        let authoritative = [
            workspace("anchor", groupID: "g"),
            workspace("member", groupID: "g", unread: true),
        ]
        let displayed = MobileWorkspaceOptimisticOrder(workspaces: authoritative)
            .materializedWorkspaces(from: authoritative)
        let expanded = MobileWorkspaceListItem.items(workspaces: displayed, groups: [group("g", collapsed: false)])
        let collapsed = MobileWorkspaceListItem.items(workspaces: displayed, groups: [group("g", collapsed: true)])

        #expect(expanded.map(\.id) == ["group.g", "workspace.member", "groupFooter.g"])
        #expect(collapsed.map(\.id) == ["group.g"])
        guard case .groupHeader(_, hasUnread: true) = collapsed[0] else {
            Issue.record("Collapsed header did not rematerialize its aggregate unread state")
            return
        }
    }

    @Test func deletedWorkspaceDropsOutOfHeldOrder() {
        let base = order(["a", "b", "c", "d"])
        let optimistic = order(["b", "a", "d", "c"])
        let authoritative = snapshots(["a", "c", "d"])
        let state = MobileWorkspaceOptimisticOrderReconciler(
            optimisticOrder: optimistic,
            pendingBases: [base]
        ).reconciling(authoritative: authoritative)
        let displayed = state.optimisticOrder?.materializedWorkspaces(from: authoritative)

        #expect(state.optimisticOrder == optimistic)
        #expect(displayed?.map(\.id.rawValue) == ["a", "d", "c"])
    }

    @Test func newWorkspaceAppearsBesideItsAuthoritativeNeighbor() {
        let base = order(["a", "b", "c"])
        let optimistic = order(["b", "a", "c"])
        let authoritative = snapshots(["a", "new", "b", "c"])
        let state = MobileWorkspaceOptimisticOrderReconciler(
            optimisticOrder: optimistic,
            pendingBases: [base]
        ).reconciling(authoritative: authoritative)
        let displayed = state.optimisticOrder?.materializedWorkspaces(from: authoritative)

        #expect(state.optimisticOrder == optimistic)
        #expect(displayed?.map(\.id.rawValue) == ["b", "a", "new", "c"])
    }
    @Test func workspacePinChangeSupersedesHeldOptimism() {
        let predicted = [workspace("b"), workspace("a")]
        let base = [workspace("a"), workspace("b")]
        let state = MobileWorkspaceOptimisticOrderReconciler(
            optimisticOrder: MobileWorkspaceOptimisticOrder(workspaces: predicted),
            pendingBases: [MobileWorkspaceOptimisticOrder(workspaces: base)]
        )
        // The Mac pinned "a" while the move was in flight and clamped the
        // reorder to a no-op; the same-order snapshot must supersede instead
        // of matching the stale base.
        let pinnedSnapshot = [workspace("a", pinned: true), workspace("b")]
        let next = state.reconciling(authoritative: pinnedSnapshot)
        #expect(next.optimisticOrder == nil)
        #expect(next.pendingBases.isEmpty)
    }

    @Test func groupPinChangeSupersedesHeldOptimism() {
        let members = [workspace("anchor", groupID: "g"), workspace("m", groupID: "g"), workspace("r")]
        let predicted = [workspace("anchor", groupID: "g"), workspace("r"), workspace("m", groupID: "g")]
        let unpinnedGroup = [group("g", collapsed: false)]
        let state = MobileWorkspaceOptimisticOrderReconciler(
            optimisticOrder: MobileWorkspaceOptimisticOrder(workspaces: predicted, groups: unpinnedGroup),
            pendingBases: [MobileWorkspaceOptimisticOrder(workspaces: members, groups: unpinnedGroup)]
        )
        let pinnedGroup = [group("g", collapsed: false, pinned: true)]
        let next = state.reconciling(authoritative: members, groups: pinnedGroup)
        #expect(next.optimisticOrder == nil)
        #expect(next.pendingBases.isEmpty)
    }

}
