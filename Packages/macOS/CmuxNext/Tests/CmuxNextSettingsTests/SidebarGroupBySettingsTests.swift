import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Leo (2026-10-06): the Projects menu's Group By (None or Folder) is
/// `sidebar.groupBy` in cmux.json.
@Suite struct SidebarGroupBySettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func noneByDefault() throws {
        #expect(try parse("{}").sidebarSections.groupBy == .none)
    }

    @Test func folderParses() throws {
        #expect(try parse(#"{"sidebar": {"groupBy": "folder"}}"#).sidebarSections.groupBy == .folder)
    }

    @Test func aBadValueIsNone() throws {
        let snapshot = try parse(#"{"sidebar": {"groupBy": "repo"}}"#)
        #expect(snapshot.sidebarSections.groupBy == .none)
        #expect(snapshot.diagnostics.map(\.path) == ["sidebar.groupBy"])
    }

    @Test func settingsListsItAsAChoice() {
        guard case let .choice(choices)? = SettingsSchema.descriptor(for: ["sidebar", "groupBy"])?.kind else {
            Issue.record("sidebar.groupBy is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["none", "folder"])
    }
}
