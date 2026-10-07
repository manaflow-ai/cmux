import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The bottom launcher strip (not a layout dock column) stays opt-in and accepts both exploration variants.
@Suite struct SidebarLauncherModeSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func launcherIsOffByDefaultAndParsesBothVariants() throws {
        #expect(try parse("{}").sidebarSections.launcherMode == .off)
        for mode in SidebarLauncherMode.allCases {
            #expect(try parse(#"{"sidebar":{"launcherMode":"\#(mode.rawValue)"}}"#).sidebarSections.launcherMode == mode)
        }
    }

    @Test func invalidLauncherModeFallsBackAndReportsThePath() throws {
        let snapshot = try parse(#"{"sidebar":{"launcherMode":"always"}}"#)
        #expect(snapshot.sidebarSections.launcherMode == .off)
        #expect(snapshot.diagnostics.map(\.path) == ["sidebar.launcherMode"])
    }

    @Test func launcherModeIsAnAgentSettableSchemaChoice() {
        let descriptor = SettingsSchema.descriptor(for: ["sidebar", "launcherMode"])
        #expect(descriptor?.defaultValue == .string("off"))
        if case let .choice(choices)? = descriptor?.kind {
            #expect(choices.map(\.value) == ["off", "reserved", "overlay"])
        } else {
            Issue.record("launcher mode should be a choice")
        }
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.launcherMode"))
    }
}
