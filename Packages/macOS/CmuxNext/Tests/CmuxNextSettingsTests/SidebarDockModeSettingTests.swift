import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The bottom destination dock stays opt-in and accepts both exploration variants.
@Suite struct SidebarDockModeSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func dockIsOffByDefaultAndParsesBothVariants() throws {
        #expect(try parse("{}").sidebarSections.dockMode == .off)
        for mode in SidebarDockMode.allCases {
            #expect(try parse(#"{"sidebar":{"dockMode":"\#(mode.rawValue)"}}"#).sidebarSections.dockMode == mode)
        }
    }

    @Test func invalidDockModeFallsBackAndReportsThePath() throws {
        let snapshot = try parse(#"{"sidebar":{"dockMode":"always"}}"#)
        #expect(snapshot.sidebarSections.dockMode == .off)
        #expect(snapshot.diagnostics.map(\.path) == ["sidebar.dockMode"])
    }

    @Test func dockModeIsAnAgentSettableSchemaChoice() {
        let descriptor = SettingsSchema.descriptor(for: ["sidebar", "dockMode"])
        #expect(descriptor?.defaultValue == .string("off"))
        if case let .choice(choices)? = descriptor?.kind {
            #expect(choices.map(\.value) == ["off", "reserved", "overlay"])
        } else {
            Issue.record("dock mode should be a choice")
        }
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.dockMode"))
    }
}
