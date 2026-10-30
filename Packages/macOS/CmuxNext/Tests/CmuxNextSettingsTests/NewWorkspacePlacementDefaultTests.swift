import CmuxNextSettings
import Testing

/// Leo's sidebar item B ask: "Cmd-N should create right below the selected row, inside its selected
/// group, not at bottom" and the setting is "Next to current (default) / Bottom (Chrome-style)".
/// The daemon and app must share the default so a create has one placement pass.
struct NewWorkspacePlacementDefaultTests {
    @Test func anEmptyConfigPlacesNewWorkspacesNextToCurrent() {
        #expect(CmuxConfigSnapshot.newWorkspacePlacementFallback == .afterCurrent)
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.newWorkspacePlacement == .afterCurrent, "an empty cmux-next.json reads with the next-to-current rule")
        #expect(SettingsSchema.descriptor(for: ["workspaces", "newPlacement"])?.defaultValue == .string("afterCurrent"))
    }

    @Test(arguments: [NewWorkspacePlacement.afterCurrent, .bottom])
    func everyVisiblePlacementStaysAChoice(_ placement: NewWorkspacePlacement) {
        let root = JSONValue.object(["workspaces": .object(["newPlacement": .string(placement.rawValue)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.newWorkspacePlacement == placement)
    }

    @Test func legacyTopStillParsesForExistingConfig() {
        let root = JSONValue.object(["workspaces": .object(["newPlacement": .string("top")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.newWorkspacePlacement == .top)
    }
}
