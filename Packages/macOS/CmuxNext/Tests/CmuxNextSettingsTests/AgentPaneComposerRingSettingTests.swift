@testable import CmuxNextSettings
import Testing

/// `agentPane.composerRing`: what the composer's bottom-right ring shows, the chat's context usage
/// (`context`, the default) or the account's plan usage limits (`planUsage`, 5-hour and weekly).
/// Leo: "likewise, i guess we can turn that into a 5h/weekly usage type thing instead as well for
/// some people". `agentPane.showContextUsage` still hides or shows the ring. It reaches the page on
/// the `composer` event (webviews composerSettings.ts).
struct AgentPaneComposerRingSettingTests {
    @Test func contextByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.composerRing == .context)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["composerRing"])?.stringValue == "context")
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.composerRingPath)
        #expect(row?.defaultValue == .string("context"))
        #expect(row?.section == .general)
        #expect(row?.isPaletteExposed == true)
        #expect(SettingsSchema.agentSettableKeys.contains("agentPane.composerRing"))
    }

    @Test func eachChoiceRoundTrips() {
        for ring in [AgentPaneComposerRing.planUsage, .context, .planUsage] {
            let root = JSONValue.object(["agentPane": .object(["composerRing": .string(ring.rawValue)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.composerRing == ring)
            #expect(snapshot.agentPaneComposer.pageValue.value(at: ["composerRing"])?.stringValue == ring.rawValue)
            #expect(snapshot.agentPaneComposer.showContextUsage == true)
            #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.composerRing" })
        }
    }

    @Test func aBadValueIsContextWithADiagnostic() {
        for bad: JSONValue in [.string("plan"), .string("PlanUsage"), .bool(true), .number(1)] {
            let root = JSONValue.object(["agentPane": .object(["composerRing": bad, "showContextUsage": .bool(false)])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.composerRing == .context)
            #expect(snapshot.agentPaneComposer.showContextUsage == false)
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.composerRing" })
        }
    }

    @Test func sitsNextToShowContextUsageOnTheSettingsPage() {
        let keys = SettingsPageLayout.specs.first { $0.id == "chat" }?.groups.flatMap(\.keys) ?? []
        let show = keys.firstIndex(of: "agentPane.showContextUsage")
        let ring = keys.firstIndex(of: "agentPane.composerRing")
        #expect(show != nil && ring == show.map { $0 + 1 })
    }
}
