import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `tabs.barPosition` (user 2026-10-27: "a prototype for vertical tabs in panes (on left or right
/// side) and tabs at bottom of pane… do not adjust defaults"): top (default, unchanged), bottom, and
/// the vertical prototypes left and right. Off the top edge, the window keeps the standard title bar
/// so the traffic lights never cover a pane's content.
struct TabBarPlacementSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["tabs": .object(["barPosition": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func topWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.tabBarPosition == .top)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(ChromePlacementSetting.effectiveTitlebar(snapshot) == snapshot.titlebar)
    }

    @Test(arguments: [("top", TabBarPosition.top), ("bottom", .bottom), ("left", .left), ("right", .right)])
    func eachPlacementLoads(raw: String, expected: TabBarPosition) {
        let snapshot = Self.parse(.string(raw))
        #expect(snapshot.tabBarPosition == expected)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [TabBarPosition.bottom, .left, .right])
    func offTheTopTheWindowKeepsTheStandardTitleBar(position: TabBarPosition) {
        let snapshot = Self.parse(.string(position.rawValue))
        #expect(ChromePlacementSetting.effectiveTitlebar(snapshot) == .standard)
    }

    @Test func aBadValueKeepsTopAndSaysWhy() {
        let snapshot = Self.parse(.string("sideways"))
        #expect(snapshot.tabBarPosition == .top)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.barPosition" })
    }

    @Test func theRowOffersAllFourAndDefaultsToTop() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["tabs", "barPosition"]))
        #expect(row.defaultValue == .string("top"))
        guard case .choice(let choices) = row.kind else { Issue.record("not a choice row"); return }
        #expect(choices.map(\.value) == ["top", "bottom", "left", "right"])
        #expect(row.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.barPosition"))
    }

    @Test func theNewTabPositionRowOffersBeforeTheCurrentTab() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabPosition"]))
        #expect(row.defaultValue == .string("afterCurrent"), "the default does not change")
        guard case .choice(let choices) = row.kind else { Issue.record("not a choice row"); return }
        #expect(choices.map(\.value) == ["afterCurrent", "beforeCurrent", "end", "start"])
        let snapshot = CmuxConfigSnapshot.parse(.object(["tabs": .object(["newTabPosition": .string("beforeCurrent")])]),
                                                validDensities: [], validMetrics: [])
        #expect(snapshot.newTabPosition == .beforeCurrent)
        #expect(snapshot.diagnostics.isEmpty)
    }
}
