import Testing
@testable import CmuxNextSettings

@Suite struct AgentPaneZoomSettingTests {
    @Test func parsesAndClampsZoom() {
        var diagnostics: [SettingsDiagnostic] = []
        #expect(AgentPaneZoomSetting.parse(["agentPane": ["zoom": 1.4]], diagnostics: &diagnostics) == 1.4)
        #expect(diagnostics.isEmpty)

        diagnostics = []
        #expect(AgentPaneZoomSetting.parse(["agentPane": ["zoom": 9]], diagnostics: &diagnostics) == 2)
        #expect(diagnostics.count == 1)
    }

    @Test func defaultIsActualSize() {
        var diagnostics: [SettingsDiagnostic] = []
        #expect(AgentPaneZoomSetting.parse([:], diagnostics: &diagnostics) == 1)
        #expect(diagnostics.isEmpty)
    }
}
