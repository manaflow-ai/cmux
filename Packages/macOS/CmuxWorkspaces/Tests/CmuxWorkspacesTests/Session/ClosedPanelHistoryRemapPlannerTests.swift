import Foundation
import Testing

@testable import CmuxWorkspaces

@Suite("ClosedPanelHistoryRemapPlanner")
struct ClosedPanelHistoryRemapPlannerTests {
    private let planner = ClosedPanelHistoryRemapPlanner()

    // MARK: planSessionRestoreRemaps

    @Test("session: skips nil originals and unchanged ids")
    func sessionSkipsNilAndUnchanged() {
        let unchanged = UUID()
        let original = UUID()
        let restored = UUID()
        let map = [UUID(): UUID()]
        let ops = planner.planSessionRestoreRemaps(
            originalWorkspaceIds: [nil, unchanged, original],
            restoredWorkspaceIds: [UUID(), unchanged, restored],
            panelIdMapsByIndex: [[:], [:], map]
        )
        #expect(ops.count == 1)
        #expect(ops.first?.fromWorkspaceId == original)
        #expect(ops.first?.toWorkspaceId == restored)
        #expect(ops.first?.panelIdMap == map)
    }

    @Test("session: clamps to the shorter of original/restored counts")
    func sessionClampsCount() {
        let a = UUID(); let ra = UUID()
        let ops = planner.planSessionRestoreRemaps(
            originalWorkspaceIds: [a, UUID(), UUID()],
            restoredWorkspaceIds: [ra],
            panelIdMapsByIndex: []
        )
        #expect(ops.map(\.fromWorkspaceId) == [a])
        #expect(ops.first?.toWorkspaceId == ra)
        #expect(ops.first?.panelIdMap.isEmpty == true)
    }

    @Test("session: empty inputs yield no operations")
    func sessionEmpty() {
        #expect(planner.planSessionRestoreRemaps(
            originalWorkspaceIds: [],
            restoredWorkspaceIds: [],
            panelIdMapsByIndex: []
        ).isEmpty)
    }

    @Test("session: all-unchanged yields no operations (no flush)")
    func sessionAllUnchanged() {
        let a = UUID(); let b = UUID()
        let ops = planner.planSessionRestoreRemaps(
            originalWorkspaceIds: [a, b],
            restoredWorkspaceIds: [a, b],
            panelIdMapsByIndex: [[:], [:]]
        )
        #expect(ops.isEmpty)
    }

    // MARK: planWindowRestoreRemaps

    @Test("window: remaps every aligned slot in order")
    func windowRemapsAll() {
        let o0 = UUID(); let o1 = UUID()
        let r0 = UUID(); let r1 = UUID()
        let map1 = [UUID(): UUID()]
        let ops = planner.planWindowRestoreRemaps(
            originalWorkspaceIds: [o0, o1],
            restoredWorkspaceIds: [r0, r1],
            panelIdMapsByIndex: [[:], map1]
        )
        #expect(ops.map(\.fromWorkspaceId) == [o0, o1])
        #expect(ops.map(\.toWorkspaceId) == [r0, r1])
        #expect(ops.last?.panelIdMap == map1)
    }

    @Test("window: empty originals yield no operations")
    func windowEmptyOriginals() {
        #expect(planner.planWindowRestoreRemaps(
            originalWorkspaceIds: [],
            restoredWorkspaceIds: [UUID()],
            panelIdMapsByIndex: []
        ).isEmpty)
    }

    @Test("window: clamps to shorter restored count")
    func windowClamps() {
        let o0 = UUID(); let o1 = UUID()
        let r0 = UUID()
        let ops = planner.planWindowRestoreRemaps(
            originalWorkspaceIds: [o0, o1],
            restoredWorkspaceIds: [r0],
            panelIdMapsByIndex: []
        )
        #expect(ops.map(\.fromWorkspaceId) == [o0])
        #expect(ops.first?.toWorkspaceId == r0)
    }

    @Test("window: remaps even when an id is unchanged (no skip, unlike session)")
    func windowDoesNotSkipUnchanged() {
        let same = UUID()
        let ops = planner.planWindowRestoreRemaps(
            originalWorkspaceIds: [same],
            restoredWorkspaceIds: [same],
            panelIdMapsByIndex: [[:]]
        )
        #expect(ops.count == 1)
        #expect(ops.first?.fromWorkspaceId == same)
        #expect(ops.first?.toWorkspaceId == same)
    }
}
