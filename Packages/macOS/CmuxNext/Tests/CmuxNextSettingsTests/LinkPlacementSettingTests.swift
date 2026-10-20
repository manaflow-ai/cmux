import CmuxNextSettings
import Testing

/// `layout.linkPlacement`: a link or path the person opens from a pane lands in a split on its
/// right by default; a new column or a tab in the same pane are the other choices. Agents may set
/// it (a layout choice, like `layout.newPanePlacement`).
struct LinkPlacementSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["layout": .object(["linkPlacement": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func splitRightWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.linkPlacement == .splitRight)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [("split-right", LinkPlacement.splitRight), ("new-column", .newColumn), ("same-pane", .samePane)])
    func eachChoiceLoads(raw: String, expected: LinkPlacement) {
        #expect(Self.parse(.string(raw)).linkPlacement == expected)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("left"))
        #expect(snapshot.linkPlacement == .splitRight)
        #expect(snapshot.diagnostics.contains { $0.path == "layout.linkPlacement" })
    }

    @Test func theRowMatchesTheAppAndAgentsMaySetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["layout", "linkPlacement"]))
        #expect(row.defaultValue == .string("split-right"))
        #expect(SettingsSchema.agentSettableKeys.contains("layout.linkPlacement"))
        #expect(SettingsSchema.agentRefusedKeys["layout.linkPlacement"] == nil)
    }
}
