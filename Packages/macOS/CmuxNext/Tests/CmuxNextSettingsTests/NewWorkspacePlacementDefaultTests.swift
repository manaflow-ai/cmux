import CmuxNextSettings
import Testing

/// Every new workspace goes to the top of the sidebar by default, below Pinned and Home (Lawrence
/// 2026-11-12: "by default all new workspaces should go to the top", after users saw new workspaces
/// still spawn at the bottom; it was `afterCurrent` from 2026-11-06, `top` from 2026-10-20). The
/// daemon's and the Chief's default is the same, and the new row shows at its slot from the press
/// (`PendingWorkspaceRows`). `afterCurrent` and `bottom` stay choices.
struct NewWorkspacePlacementDefaultTests {
    @Test func anEmptyConfigPlacesNewWorkspacesAtTheTop() {
        #expect(CmuxConfigSnapshot.newWorkspacePlacementDefault == .top)
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.newWorkspacePlacement == .top, "an empty cmux-next.json reads with the top rule")
        #expect(SettingsSchema.descriptor(for: ["workspaces", "newPlacement"])?.defaultValue == .string("top"))
    }

    @Test func aValueTheAppDoesNotKnowFallsBackToTheTop() {
        let root = JSONValue.object(["workspaces": .object(["newPlacement": .string("sideways")])])
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).newWorkspacePlacement == .top)
    }

    @Test(arguments: [NewWorkspacePlacement.afterCurrent, .bottom, .top])
    func everyPlacementStaysAChoice(_ placement: NewWorkspacePlacement) {
        let root = JSONValue.object(["workspaces": .object(["newPlacement": .string(placement.rawValue)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.newWorkspacePlacement == placement)
    }
}
