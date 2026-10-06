import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// R109 `tabs.barPosition`: top (default) or bottom. Bottom needs a title
/// bar row for the traffic lights, so the window uses the standard one.
@MainActor @Suite struct TabBarPositionSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test func parsesWithADefaultAndADiagnostic() throws {
        #expect(try parse("{}").tabBarPosition == .top)
        #expect(try parse(#"{"tabs": {"barPosition": "bottom"}}"#).tabBarPosition == .bottom)
        let bad = try parse(#"{"tabs": {"barPosition": "left"}}"#)
        #expect(bad.tabBarPosition == .top && bad.diagnostics.map(\.path) == ["tabs.barPosition"])
    }

    @Test func isASchemaChoiceAgentsMaySet() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "barPosition"]))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("expected a choice")
            return
        }
        #expect(choices.map(\.value) == ["top", "bottom"])
        #expect(descriptor.defaultValue == "top" && descriptor.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.barPosition"))
    }

    @Test func bottomUsesTheStandardTitlebar() throws {
        let minimal = try parse(#"{"window": {"titlebar": "minimal"}, "tabs": {"barPosition": "bottom"}}"#)
        #expect(ChromePlacementSetting.effectiveTitlebar(minimal) == .standard)
        let top = try parse(#"{"window": {"titlebar": "minimal"}}"#)
        #expect(ChromePlacementSetting.effectiveTitlebar(top) == .minimal)
        let design = DesignSettings()
        SettingsApplier.applyPlacement(minimal, to: design)
        #expect(design.tabBarPosition == .bottom)
    }
}
