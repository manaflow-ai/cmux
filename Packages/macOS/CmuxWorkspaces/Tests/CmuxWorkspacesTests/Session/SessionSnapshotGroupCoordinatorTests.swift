import Foundation
import Testing

@testable import CmuxWorkspaces

@Suite("SessionSnapshotGroupCoordinator")
struct SessionSnapshotGroupCoordinatorTests {
    private let coordinator = SessionSnapshotGroupCoordinator()

    private func group(
        id: UUID,
        name: String = "Group",
        isCollapsed: Bool = false,
        isPinned: Bool = false,
        anchor: UUID,
        customColor: String? = nil,
        iconSymbol: String? = nil
    ) -> WorkspaceGroup {
        WorkspaceGroup(
            id: id,
            name: name,
            isCollapsed: isCollapsed,
            isPinned: isPinned,
            anchorWorkspaceId: anchor,
            customColor: customColor,
            iconSymbol: iconSymbol
        )
    }

    // MARK: assembleGroupSnapshots

    @Test("assemble drops unoccupied groups and preserves order")
    func assembleDropsUnoccupied() {
        let a = UUID(); let b = UUID()
        let m1 = UUID(); let m2 = UUID()
        let groups = [
            group(id: a, name: "A", anchor: m1),
            group(id: b, name: "B", anchor: m2),
        ]
        let snapshots = coordinator.assembleGroupSnapshots(
            groups: groups,
            occupiedGroupIds: [a],
            restorableMemberIdsByGroupId: [a: [m1]]
        )
        #expect(snapshots?.map(\.id) == [a])
        #expect(snapshots?.first?.name == "A")
    }

    @Test("assemble records anchor member index in tab order")
    func assembleRecordsAnchorIndex() {
        let g = UUID()
        let m0 = UUID(); let m1 = UUID(); let m2 = UUID()
        let snapshots = coordinator.assembleGroupSnapshots(
            groups: [group(id: g, anchor: m1)],
            occupiedGroupIds: [g],
            restorableMemberIdsByGroupId: [g: [m0, m1, m2]]
        )
        #expect(snapshots?.first?.anchorMemberIndex == 1)
        #expect(snapshots?.first?.anchorWorkspaceId == m1)
    }

    @Test("assemble yields nil anchor index when anchor is not a restorable member")
    func assembleNilAnchorIndexWhenAnchorDropped() {
        let g = UUID()
        let m0 = UUID(); let anchorMissing = UUID()
        let snapshots = coordinator.assembleGroupSnapshots(
            groups: [group(id: g, anchor: anchorMissing)],
            occupiedGroupIds: [g],
            restorableMemberIdsByGroupId: [g: [m0]]
        )
        #expect(snapshots?.first?.anchorMemberIndex == nil)
        #expect(snapshots?.first?.anchorWorkspaceId == anchorMissing)
    }

    @Test("assemble returns nil when no group survives")
    func assembleReturnsNilWhenEmpty() {
        let snapshots = coordinator.assembleGroupSnapshots(
            groups: [group(id: UUID(), anchor: UUID())],
            occupiedGroupIds: [],
            restorableMemberIdsByGroupId: [:]
        )
        #expect(snapshots == nil)
    }

    @Test("assemble carries pin/color/icon through")
    func assembleCarriesMetadata() {
        let g = UUID(); let m = UUID()
        let snapshots = coordinator.assembleGroupSnapshots(
            groups: [group(id: g, isCollapsed: true, isPinned: true, anchor: m, customColor: "#abc", iconSymbol: "star")],
            occupiedGroupIds: [g],
            restorableMemberIdsByGroupId: [g: [m]]
        )
        let snap = snapshots?.first
        #expect(snap?.isCollapsed == true)
        #expect(snap?.isPinned == true)
        #expect(snap?.customColor == "#abc")
        #expect(snap?.iconSymbol == "star")
    }

    // MARK: restoreGroups

    @Test("restore returns empty when snapshot has no groups")
    func restoreEmptyWhenNil() {
        let groups = coordinator.restoreGroups(groupSnapshots: nil, memberIdsByGroupId: [:])
        #expect(groups.isEmpty)
    }

    @Test("restore drops groups with no restored members")
    func restoreDropsMemberless() {
        let g = UUID()
        let snap = SessionWorkspaceGroupSnapshot(id: g, name: "G", isCollapsed: false, anchorMemberIndex: 0)
        let groups = coordinator.restoreGroups(groupSnapshots: [snap], memberIdsByGroupId: [:])
        #expect(groups.isEmpty)
    }

    @Test("restore dedupes by group id, first wins")
    func restoreDedupes() {
        let g = UUID(); let m = UUID()
        let first = SessionWorkspaceGroupSnapshot(id: g, name: "First", isCollapsed: false, anchorMemberIndex: 0)
        let second = SessionWorkspaceGroupSnapshot(id: g, name: "Second", isCollapsed: false, anchorMemberIndex: 0)
        let groups = coordinator.restoreGroups(
            groupSnapshots: [first, second],
            memberIdsByGroupId: [g: [m]]
        )
        #expect(groups.map(\.name) == ["First"])
    }

    @Test("restore resolves anchor by index first")
    func restoreAnchorByIndex() {
        let g = UUID(); let m0 = UUID(); let m1 = UUID()
        let snap = SessionWorkspaceGroupSnapshot(
            id: g, name: "G", isCollapsed: false,
            anchorWorkspaceId: UUID(), anchorMemberIndex: 1
        )
        let groups = coordinator.restoreGroups(groupSnapshots: [snap], memberIdsByGroupId: [g: [m0, m1]])
        #expect(groups.first?.anchorWorkspaceId == m1)
    }

    @Test("restore falls back to stored hint when index out of range")
    func restoreAnchorByStoredHint() {
        let g = UUID(); let m0 = UUID(); let m1 = UUID()
        let snap = SessionWorkspaceGroupSnapshot(
            id: g, name: "G", isCollapsed: false,
            anchorWorkspaceId: m1, anchorMemberIndex: 9
        )
        let groups = coordinator.restoreGroups(groupSnapshots: [snap], memberIdsByGroupId: [g: [m0, m1]])
        #expect(groups.first?.anchorWorkspaceId == m1)
    }

    @Test("restore falls back to first member when neither index nor hint resolves")
    func restoreAnchorFirstMember() {
        let g = UUID(); let m0 = UUID(); let m1 = UUID()
        let snap = SessionWorkspaceGroupSnapshot(
            id: g, name: "G", isCollapsed: false,
            anchorWorkspaceId: nil, anchorMemberIndex: nil
        )
        let groups = coordinator.restoreGroups(groupSnapshots: [snap], memberIdsByGroupId: [g: [m0, m1]])
        #expect(groups.first?.anchorWorkspaceId == m0)
    }

    @Test("restore defaults isPinned to false when omitted")
    func restorePinDefault() {
        let g = UUID(); let m = UUID()
        let snap = SessionWorkspaceGroupSnapshot(id: g, name: "G", isCollapsed: false, anchorMemberIndex: 0, isPinned: nil)
        let groups = coordinator.restoreGroups(groupSnapshots: [snap], memberIdsByGroupId: [g: [m]])
        #expect(groups.first?.isPinned == false)
    }
}
