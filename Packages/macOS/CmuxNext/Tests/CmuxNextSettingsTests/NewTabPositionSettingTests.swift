import CmuxNextSettings
import Testing

/// `tabs.newTabPosition` (Lawrence 2026-10-20): Cmd-T puts the new tab right
/// after the current tab by default; "end" and "start" are the other choices. Agents may set it.
struct NewTabPositionSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["tabs": .object(["newTabPosition": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func afterTheCurrentTabWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.newTabPosition == .afterCurrent)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [("afterCurrent", NewTabPosition.afterCurrent), ("end", .end), ("start", .start)])
    func eachChoiceLoads(raw: String, expected: NewTabPosition) {
        let snapshot = Self.parse(.string(raw))
        #expect(snapshot.newTabPosition == expected)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("left"))
        #expect(snapshot.newTabPosition == .afterCurrent)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.newTabPosition" })
    }

    @Test func theRowOffersAllThreeAndDefaultsToAfterCurrent() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabPosition"]))
        #expect(row.defaultValue == .string("afterCurrent"))
        guard case .choice(let choices) = row.kind else { Issue.record("not a choice row"); return }
        #expect(choices.map(\.value) == ["afterCurrent", "end", "start"])
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabPosition"))
    }
}

/// `tabs.newTabButtonPosition` (Lucas 2026-11-07): where the strip's + puts the new tab, apart
/// from Cmd-T. The end by default, as the + sits after the last tab. Agents may set it.
struct NewTabButtonPositionSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["tabs": .object(["newTabButtonPosition": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func theEndWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.newTabButtonPosition == .end)
        #expect(snapshot.newTabPosition == .afterCurrent, "Cmd-T keeps its own default")
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [("afterCurrent", NewTabPosition.afterCurrent), ("end", .end), ("start", .start)])
    func eachChoiceLoads(raw: String, expected: NewTabPosition) {
        let snapshot = Self.parse(.string(raw))
        #expect(snapshot.newTabButtonPosition == expected)
        #expect(snapshot.newTabPosition == .afterCurrent, "the + setting never moves Cmd-T's tab")
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("left"))
        #expect(snapshot.newTabButtonPosition == .end)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.newTabButtonPosition" })
    }

    @Test func theRowOffersAllThreeDefaultsToTheEndAndAgentsMaySetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabButtonPosition"]))
        #expect(row.defaultValue == .string("end"))
        guard case .choice(let choices) = row.kind else { Issue.record("not a choice row"); return }
        #expect(choices.map(\.value) == ["afterCurrent", "end", "start"])
        #expect(row.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabButtonPosition"))
    }
}
