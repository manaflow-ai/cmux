import CmuxNextSettings
import Testing

/// `layout.mainPane`: an agent chat is its screen's main pane by default (Leo 2026-10-20); "off"
/// turns that off. Agents may set it (a layout choice, like `layout.linkPlacement`).
struct MainPaneSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["layout": .object(["mainPane": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func agentChatsWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.mainPane == .agentChats)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [("agent-chats", MainPaneSetting.agentChats), ("off", .off)])
    func eachChoiceLoads(raw: String, expected: MainPaneSetting) {
        #expect(Self.parse(.string(raw)).mainPane == expected)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.bool(false))
        #expect(snapshot.mainPane == .agentChats)
        #expect(snapshot.diagnostics.contains { $0.path == "layout.mainPane" })
    }

    @Test func theRowMatchesTheAppAndAgentsMaySetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["layout", "mainPane"]))
        #expect(row.defaultValue == .string("agent-chats"))
        #expect(SettingsSchema.agentSettableKeys.contains("layout.mainPane"))
        #expect(SettingsSchema.agentRefusedKeys["layout.mainPane"] == nil)
    }
}
