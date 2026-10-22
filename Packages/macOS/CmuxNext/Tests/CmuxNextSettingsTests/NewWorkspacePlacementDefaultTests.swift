import CmuxNextSettings
import Testing

/// Cmd-N puts the new workspace at the top by default (Lawrence 2026-10-20: "Always make it at the
/// top with a single state change, a single render, and have zero jank";
/// plans/cmux-next/sidebar-ordering-DESIGN.md). The daemon places every new workspace by the same
/// setting in its create, and its default is `top`: an app default of `afterCurrent` (#23014) made the
/// app move each new workspace after the daemon placed it, a second state change. `afterCurrent` and
/// `bottom` stay choices.
struct NewWorkspacePlacementDefaultTests {
    @Test func anEmptyConfigPlacesNewWorkspacesAtTheTop() {
        #expect(CmuxConfigSnapshot.newWorkspacePlacementFallback == .top)
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.newWorkspacePlacement == .top, "an empty cmux-next.json reads with the top rule")
        #expect(SettingsSchema.descriptor(for: ["workspaces", "newPlacement"])?.defaultValue == .string("top"))
    }

    @Test(arguments: [NewWorkspacePlacement.afterCurrent, .bottom, .top])
    func everyPlacementStaysAChoice(_ placement: NewWorkspacePlacement) {
        let root = JSONValue.object(["workspaces": .object(["newPlacement": .string(placement.rawValue)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.newWorkspacePlacement == placement)
    }
}
