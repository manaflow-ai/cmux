import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// "Tile subagents automatically" (#20694, the coordinator's call): the Subagents card's switch is
/// also a Settings row, off by default. cmux.json holds it (`agentPane.tileSubagentsAutomatically`),
/// the host pushes it to every chat page with the composer's flags, and the card's switch asks the
/// host to write it, so both places show the same value, also after a relaunch.
struct TileSubagentsSettingTests {
    static let path = ["agentPane", "tileSubagentsAutomatically"]

    @Test func settingsHasAnOffToggleRowForIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path), "Settings shows the switch")
        #expect(row.kind == .toggle)
        #expect(row.defaultValue == .bool(false), "off unless turned on")
    }

    @Test func cmuxJSONReachesEveryChatPage() {
        let on = JSONValue.object(["agentPane": .object(["tileSubagentsAutomatically": .bool(true)])])
        let snapshot = CmuxConfigSnapshot.parse(on, validDensities: [], validMetrics: [])
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
        #expect(AgentPageEvent.composer(snapshot.agentPaneComposer).value["tileSubagentsAutomatically"] == .bool(true))

        let unset = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(AgentPageEvent.composer(unset.agentPaneComposer).value["tileSubagentsAutomatically"] == .bool(false))
    }

    @Test func theCardsSwitchWritesTheSetting() {
        #expect(AgentPageOps.all.contains(AgentPageOps.namespace + "pane.tileSubagentsAutomatically"))
        let request = AgentPaneRequest(body: ["method": "pane.tileSubagentsAutomatically", "params": ["show": true]])
        #expect(request == .composerSetting(path: Self.path, show: true))
    }
}
