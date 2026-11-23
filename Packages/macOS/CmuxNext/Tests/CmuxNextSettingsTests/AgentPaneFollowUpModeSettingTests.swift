import CmuxNextSettings
import Testing

/// `agentPane.followUpMode` (steer, queue): what Return and Send do with a message sent while an
/// agent that steers is mid-turn. It reaches the page on the `composer` event (webviews
/// composerSettings.ts, followUpMode.ts) and defaults to today's behaviour: Return steers.
struct AgentPaneFollowUpModeSettingTests {
    @Test func defaultsKeepTodaysBehaviour() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.followUpMode == .steer)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["followUpMode"])?.stringValue == "steer")
        #expect(SettingsSchema.descriptor(for: AgentPaneComposerSetting.followUpModePath)?.defaultValue == .string("steer"))
    }

    @Test func queueRoundTrips() {
        let root = JSONValue.object(["agentPane": .object(["followUpMode": .string("queue")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.followUpMode == .queue)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["followUpMode"])?.stringValue == "queue")
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("agentPane.") })
    }

    @Test func agentsMaySetIt() {
        #expect(SettingsSchema.agentSettableKeys.contains("agentPane.followUpMode"))
        #expect(SettingsSchema.agentRefusedKeys["agentPane.followUpMode"] == nil)
    }

    @Test func aBadValueIsTheDefaultWithADiagnostic() {
        for bad: JSONValue in [.string("Queue"), .string("interrupt"), .bool(true)] {
            let root = JSONValue.object(["agentPane": .object(["followUpMode": bad])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.followUpMode == .steer)
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.followUpMode" })
        }
    }
}
