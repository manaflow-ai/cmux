import CmuxNextSettings
import Testing

/// `links.openTarget`: where a link opened from an agent chat goes. The rightmost split of the
/// chat's screen by default (Leo 2026-10-21); "newSplit" always splits right of the chat; "sameTab"
/// keeps the old tab in the chat's pane. Agents may set it (a layout choice, like `layout.linkPlacement`).
struct ChatLinkTargetSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["links": .object(["openTarget": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func rightmostWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.chatLinkTarget == .rightmost)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [("rightmost", ChatLinkTarget.rightmost), ("newSplit", .newSplit), ("sameTab", .sameTab)])
    func eachChoiceLoads(raw: String, expected: ChatLinkTarget) {
        #expect(Self.parse(.string(raw)).chatLinkTarget == expected)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("left"))
        #expect(snapshot.chatLinkTarget == .rightmost)
        #expect(snapshot.diagnostics.contains { $0.path == "links.openTarget" })
    }

    @Test func theRowMatchesTheAppAndAgentsMaySetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["links", "openTarget"]))
        #expect(row.defaultValue == .string("rightmost"))
        #expect(SettingsSchema.agentSettableKeys.contains("links.openTarget"))
        #expect(SettingsSchema.agentRefusedKeys["links.openTarget"] == nil)
    }
}
