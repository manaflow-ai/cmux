import CmuxNextSettings
import Testing

/// `agentPane.composerPlaceholder`: the empty message box's text, a setting a profile can carry
/// (examples/looks/t3code). Empty, the default, keeps cmux's own; it reaches the page on the
/// `composer` event (webviews composerSettings.ts, Composer.tsx).
struct AgentPaneComposerPlaceholderSettingTests {
    @Test func defaultIsEmpty() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.composerPlaceholder == "")
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["composerPlaceholder"])?.stringValue == "")
        #expect(SettingsSchema.descriptor(for: AgentPaneComposerSetting.composerPlaceholderPath)?.defaultValue == .string(""))
    }

    @Test func textRoundTrips() {
        let text = "Ask for changes, send follow-ups, or attach images"
        let root = JSONValue.object(["agentPane": .object(["composerPlaceholder": .string(text)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.composerPlaceholder == text)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["composerPlaceholder"])?.stringValue == text)
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("agentPane.") })
    }

    @Test func agentsMaySetIt() {
        #expect(SettingsSchema.agentSettableKeys.contains("agentPane.composerPlaceholder"))
        #expect(SettingsSchema.agentRefusedKeys["agentPane.composerPlaceholder"] == nil)
    }

    @Test func aNonStringIsTheDefaultWithADiagnostic() {
        for bad: JSONValue in [.bool(true), .number(3)] {
            let root = JSONValue.object(["agentPane": .object(["composerPlaceholder": bad])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.composerPlaceholder == "")
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.composerPlaceholder" })
        }
    }
}
