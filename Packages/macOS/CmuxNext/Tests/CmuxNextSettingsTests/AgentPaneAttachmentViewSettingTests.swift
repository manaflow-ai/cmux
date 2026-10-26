import CmuxNextSettings
import Testing

/// `agentPane.attachmentView`: how the composer and sent messages show attachments, strip by
/// default (Leo: "the actual input, as a default, I don't think it's gonna be worse to put the
/// things inline, like how iMessage on Mac does it"). It reaches the page on the `composer` event
/// (webviews composerSettings.ts).
struct AgentPaneAttachmentViewSettingTests {
    @Test func stripByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.attachmentView == .strip)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["attachmentView"])?.stringValue == "strip")
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.attachmentViewPath)
        #expect(row?.defaultValue == .string("strip"))
        #expect(row?.section == .general)
    }

    @Test func eachChoiceRoundTrips() {
        for view in [AgentPaneAttachmentView.strip, .inline, .strip, .inline] {
            let root = JSONValue.object(["agentPane": .object(["attachmentView": .string(view.rawValue)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.attachmentView == view)
            #expect(snapshot.agentPaneComposer.pageValue.value(at: ["attachmentView"])?.stringValue == view.rawValue)
            #expect(snapshot.agentPaneComposer.showDictation == true)
            #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.attachmentView" })
        }
    }

    @Test func aBadValueIsStripWithADiagnostic() {
        for bad: JSONValue in [.string("row"), .string("Strip"), .bool(true), .number(1)] {
            let root = JSONValue.object(["agentPane": .object(["attachmentView": bad, "spellChecking": .bool(true)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.attachmentView == .strip)
            #expect(snapshot.agentPaneComposer.spellChecking == true)
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.attachmentView" })
        }
    }
}
