import CmuxNextSettings
import Testing

/// Cmd-N puts the new workspace right after the current one by default (Leo 2026-11-06: "you should
/// just have it right next to it"; it was `top` from 2026-10-20, Lawrence: "Always make it at the top
/// with a single state change, a single render, and have zero jank"). The daemon's default is the
/// same, and the new row shows at its slot from the press (`PendingWorkspaceRows`), so the app's move
/// after the daemon's create shows no jump. `top` and `bottom` stay choices.
struct NewWorkspacePlacementDefaultTests {
    @Test func anEmptyConfigPlacesNewWorkspacesAfterTheCurrentOne() {
        #expect(CmuxConfigSnapshot.newWorkspacePlacementDefault == .afterCurrent)
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.newWorkspacePlacement == .afterCurrent, "an empty cmux-next.json reads with the afterCurrent rule")
        #expect(SettingsSchema.descriptor(for: ["workspaces", "newPlacement"])?.defaultValue == .string("afterCurrent"))
    }

    @Test(arguments: [NewWorkspacePlacement.afterCurrent, .bottom, .top])
    func everyPlacementStaysAChoice(_ placement: NewWorkspacePlacement) {
        let root = JSONValue.object(["workspaces": .object(["newPlacement": .string(placement.rawValue)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.newWorkspacePlacement == placement)
    }
}
