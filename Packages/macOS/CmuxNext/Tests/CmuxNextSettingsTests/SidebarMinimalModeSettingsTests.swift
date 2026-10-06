import CmuxNextDesign
import CmuxNextSettings
import Testing

/// R54 (Lawrence 2026-10-03): minimal mode hides chosen pinned sections
/// (the first choice: the Settings and account row at the bottom) until the
/// pointer is over the sidebar. A cmux.json setting in the schema that
/// agents may set.
@Suite struct SidebarMinimalModeSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    /// The footer's avatar and gear are always drawn by default (Leo 2026-10-06:
    /// the hover-only footer read as missing buttons); hiding the bottom band
    /// until hover is the opt-in `"bottom"` choice.
    @Test func minimalModeIsOffByDefaultAndTakesItsChoices() throws {
        #expect(try parse("{}").sidebarSections.minimalMode == .off)
        for mode in SidebarMinimalMode.allCases {
            let snapshot = try parse(#"{"sidebar": {"minimalMode": "\#(mode.rawValue)"}}"#)
            #expect(snapshot.sidebarSections.minimalMode == mode && snapshot.diagnostics.isEmpty, "\(mode)")
        }
        let bad = try parse(#"{"sidebar": {"minimalMode": "sideways"}}"#)
        #expect(bad.sidebarSections.minimalMode == .off)
        #expect(bad.diagnostics.map(\.path) == ["sidebar.minimalMode"])
    }

    @Test func theSchemaListsItAndAgentsMaySetIt() {
        let descriptor = SettingsSchema.descriptor(for: ["sidebar", "minimalMode"])
        #expect(descriptor?.defaultValue == .string("off"))
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.minimalMode"))
        #expect(SidebarMinimalMode.bottom.hidesBottom && !SidebarMinimalMode.bottom.hidesTop)
        #expect(SidebarMinimalMode.both.hidesBottom && SidebarMinimalMode.both.hidesTop)
        #expect(!SidebarMinimalMode.off.hidesBottom && !SidebarMinimalMode.off.hidesTop)
    }
}
