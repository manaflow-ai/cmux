import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// SIDEBAR-NUMBERING-AND-STEPPING: `sidebar.numbering`, `sidebar.cmd9`,
/// `sidebar.stepping`, `sidebar.steppingWraps` in cmux.json, in the schema
/// (Settings > Appearance > Sidebar), settable by agents, with the defaults
/// the docs state (allItems, last, allItems, true).
@Suite struct SidebarNavigationSettingTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaults() throws {
        let navigation = try parse("{}").sidebarSections.navigation
        #expect(navigation == SidebarNavigationSettings(numbering: .allItems, cmd9: .last, stepping: .allItems, steppingWraps: true))
    }

    @Test func everyValueParses() throws {
        let snapshot = try parse(#"{"sidebar": {"numbering": "workspacesOnly", "cmd9": "ninth", "stepping": "workspacesOnly", "steppingWraps": false}}"#)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(snapshot.sidebarSections.navigation
            == SidebarNavigationSettings(numbering: .workspacesOnly, cmd9: .ninth, stepping: .workspacesOnly, steppingWraps: false))
    }

    @Test func aBadValueIsTheDefaultWithADiagnostic() throws {
        let snapshot = try parse(#"{"sidebar": {"numbering": "some", "cmd9": 9, "steppingWraps": "yes"}}"#)
        #expect(snapshot.sidebarSections.navigation == .defaults)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["sidebar.numbering", "sidebar.cmd9", "sidebar.steppingWraps"])
    }

    @Test func theSchemaListsThemWithTheDocumentedDefaultsAndAgentsMaySetThem() {
        let expected: [(String, JSONValue)] = [("numbering", .string("allItems")), ("cmd9", .string("last")),
                                                  ("stepping", .string("allItems")), ("steppingWraps", .bool(true))]
        for (key, value) in expected {
            #expect(SettingsSchema.descriptor(for: ["sidebar", key])?.defaultValue == value, "\(key)")
            #expect(SettingsSchema.agentSettableKeys.contains("sidebar.\(key)"), "\(key)")
        }
    }
}
