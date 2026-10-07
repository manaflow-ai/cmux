import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// R109 `tabs.barOrder`: the tab bar above (default) or below a browser
/// pane's toolbar.
@MainActor @Suite struct TabBarOrderSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test func parsesWithADefaultAndADiagnostic() throws {
        #expect(try parse("{}").tabBarOrder == .aboveToolbar)
        #expect(try parse(#"{"tabs": {"barOrder": "belowToolbar"}}"#).tabBarOrder == .belowToolbar)
        let bad = try parse(#"{"tabs": {"barOrder": "sideways"}}"#)
        #expect(bad.tabBarOrder == .aboveToolbar && bad.diagnostics.map(\.path) == ["tabs.barOrder"])
        let design = DesignSettings()
        SettingsApplier.applyPlacement(try parse(#"{"tabs": {"barOrder": "belowToolbar"}}"#), to: design)
        #expect(design.tabBarOrder == .belowToolbar)
    }

    @Test func isASchemaChoiceAgentsMaySet() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "barOrder"]))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("expected a choice")
            return
        }
        #expect(choices.map(\.value) == ["aboveToolbar", "belowToolbar"])
        #expect(descriptor.defaultValue == "aboveToolbar" && descriptor.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.barOrder"))
    }
}
