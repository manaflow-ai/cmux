import CmuxNextSettings
import Testing

/// `agentPane.newChatsIn` (Settings > Agent Chat > Start New Chats In): where a new chat runs when
/// its composer picks nothing, Auto by default (Leo, 2026-11-18: Auto as the default for new chats, with a
/// setting to turn it off). It reaches the page on the `composer` event (webviews composerSettings.ts,
/// runLocationDefault.ts).
struct AgentPaneNewChatsInSettingTests {
    @Test func autoByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.newChatsIn == .auto)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["newChatsIn"])?.stringValue == "auto")
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.newChatsInPath)
        #expect(row?.defaultValue == .string("auto"))
        #expect(row?.section == .general)
    }

    /// Turning Auto off: This Mac, as before Auto.
    @Test func thisMacRoundTrips() {
        let root = JSONValue.object(["agentPane": .object(["newChatsIn": .string("local")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.newChatsIn == .local)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["newChatsIn"])?.stringValue == "local")
        #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.newChatsIn" })
    }

    @Test func cloudRoundTrips() {
        let root = JSONValue.object(["agentPane": .object(["newChatsIn": .string("cloud")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.newChatsIn == .cloud)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["newChatsIn"])?.stringValue == "cloud")
        #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.newChatsIn" })
    }

    /// An agent may set it when the person asks (Leo, 2026-10-31: an agent said it wasn't allowed to).
    @Test func agentsMaySetIt() {
        #expect(SettingsSchema.agentSettableKeys.contains("agentPane.newChatsIn"))
        #expect(SettingsSchema.agentRefusedKeys["agentPane.newChatsIn"] == nil)
    }

    @Test func aBadValueIsTheDefaultWithADiagnostic() {
        for bad: JSONValue in [.string("Cloud"), .string("vm"), .string("Auto"), .bool(true)] {
            let root = JSONValue.object(["agentPane": .object(["newChatsIn": bad])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.newChatsIn == AgentPaneComposerSetting.newChatsInDefault)
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.newChatsIn" })
        }
    }
}
