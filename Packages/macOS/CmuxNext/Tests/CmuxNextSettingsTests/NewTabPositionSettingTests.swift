import CmuxNextSettings
import Testing

/// `tabs.newTabPosition` (Lawrence 2026-10-20): Cmd-T and the strip's + put the new tab right
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

    @Test(arguments: [("afterCurrent", NewTabPosition.afterCurrent), ("beforeCurrent", .beforeCurrent), ("end", .end), ("start", .start)])
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

    @Test func theRowOffersAllFourAndDefaultsToAfterCurrent() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabPosition"]))
        #expect(row.defaultValue == .string("afterCurrent"))
        guard case .choice(let choices) = row.kind else { Issue.record("not a choice row"); return }
        #expect(choices.map(\.value) == ["afterCurrent", "beforeCurrent", "end", "start"])
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabPosition"))
    }
}
