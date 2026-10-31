import CmuxNextSettings
import Testing

/// `agentPane.newChatsIn` (Settings > Agent Chat > Start New Chats In): where a new chat runs when
/// its composer picks nothing, this Mac by default (Leo turns Cloud on himself). It reaches the page
/// on the `composer` event (webviews composerSettings.ts, runLocationDefault.ts).
struct AgentPaneNewChatsInSettingTests {
    @Test func thisMacByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.newChatsIn == .local)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["newChatsIn"])?.stringValue == "local")
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.newChatsInPath)
        #expect(row?.defaultValue == .string("local"))
        #expect(row?.section == .general)
    }

    @Test func cloudRoundTrips() {
        let root = JSONValue.object(["agentPane": .object(["newChatsIn": .string("cloud")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.newChatsIn == .cloud)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["newChatsIn"])?.stringValue == "cloud")
        #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.newChatsIn" })
    }

    @Test func aBadValueIsThisMacWithADiagnostic() {
        for bad: JSONValue in [.string("Cloud"), .string("vm"), .bool(true)] {
            let root = JSONValue.object(["agentPane": .object(["newChatsIn": bad])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.newChatsIn == .local)
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.newChatsIn" })
        }
    }
}
