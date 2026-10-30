import CmuxNextSettings
import Testing

/// `agentPane.subagentPanes` in cmux.json: whether subagents open in agent panes of their own right
/// of the chat. Off by default; the summary card's switch writes it and the page reads it from the
/// `composer` event (webviews composerSettings.ts, subagents/subagentPanes.ts).
struct AgentPaneSubagentPanesSettingTests {
    @Test func offByDefaultAndOffOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.subagentPanes == false)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["subagentPanes"])?.boolValue == false)
    }

    @Test func cmuxJSONTurnsItOnForThePage() {
        let root = JSONValue.object(["agentPane": .object(["subagentPanes": .bool(true)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.subagentPanes == true)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["subagentPanes"])?.boolValue == true)
        #expect(SettingsSchema.descriptor(for: AgentPaneComposerSetting.subagentPanesPath) != nil)
    }

    @Test func aBadValueKeepsTheDefault() {
        let root = JSONValue.object(["agentPane": .object(["subagentPanes": .string("yes")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.subagentPanes == false)
    }
}
