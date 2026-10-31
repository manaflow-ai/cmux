@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
@testable import CmuxNextSidebar
@testable import CmuxNextSettings
import Testing

/// A workspace pinned inside its group shows it at rest (`sidebar.groupPinMark`, Aziz 2026-10-30). The
/// listed row carries the document's mark (`SidebarWorkspace.isPinnedInGroup`), a feed patch keeps it, and
/// the setting reads each of its looks.
@MainActor @Suite struct SidebarGroupPinMarkTests {
    typealias Fixture = SidebarDocArchiveTests

    /// This Mac: `ws-1`, group `gm` with `ws-2` pinned inside it, `ws-3`.
    static func projection(pinned: Bool = true) -> SidebarDocProjection {
        let machine = Fixture.machine, ref = Fixture.ref
        let records = SidebarDocRecords(sections: [
            machine: SidebarDocSection(id: machine, kind: .machine(session: Fixture.session)),
        ], items: [
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
            "itm_gm": SidebarDocItem(id: "itm_gm", section: machine, body: .group(name: "G", color: nil, icon: nil, collapsed: false)),
            "itm_2": SidebarDocItem(id: "itm_2", section: machine, parent: "itm_gm", body: .workspace(ref("ws-2")), pinnedInGroup: pinned),
            "itm_3": SidebarDocItem(id: "itm_3", section: machine, body: .workspace(ref("ws-3")), pinnedInGroup: true),
        ])
        let rows = [
            SidebarDocRow(key: "itm_3", kind: "item", section: machine, item: "itm_3", ref: ref("ws-3")),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: "itm_gm", kind: "group", section: machine, item: "itm_gm"),
            SidebarDocRow(key: "itm_2", kind: "item", section: machine, parent: "itm_gm", depth: 1, item: "itm_2", ref: ref("ws-2")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static func pinned(_ sections: [CmuxNextSidebar.SidebarSection]) -> [String: Bool] {
        var marks: [String: Bool] = [:]
        for workspace in sections.flatMap(\.workspaces) { marks[workspace.id.rawValue] = workspace.isPinnedInGroup }
        return marks
    }

    @Test func aMemberPinnedInItsGroupListsMarked() {
        let marks = Self.pinned(Self.projection().arrange(Fixture.raw(), drag: Fixture.drag))
        #expect(marks["ws-2"] == true, "the group's pinned member draws the mark")
        #expect(marks["ws-1"] == false)
        #expect(marks["ws-3"] == false, "a stale mark on a loose row is not a pin in a group")
    }

    @Test func aRowPatchKeepsTheMark() throws {
        // A title or status tick patches the row in place, with no `arrange`: the mark must stay.
        let model = SidebarModel(sections: Self.projection().arrange(Fixture.raw(), drag: Fixture.drag))
        var renamed = Fixture.ws("ws-2")
        renamed.title = "renamed"
        #expect(model.patchWorkspaces([renamed]))
        #expect(Self.pinned(model.sections)["ws-2"] == true)
    }

    @Test func theSettingReadsEachLook() {
        #expect(SidebarSectionsPreferences.defaults.groupPinMark == .off, "a new look is opt-in until one is picked")
        for mark in SidebarGroupPinMark.allCases {
            var diagnostics: [SettingsDiagnostic] = []
            let root = CmuxNextSettings.JSONValue.object(["sidebar": .object(["groupPinMark": .string(mark.rawValue)])])
            #expect(SidebarSectionsSetting.parse(root, diagnostics: &diagnostics).groupPinMark == mark)
            #expect(diagnostics.isEmpty)
        }
        var diagnostics: [SettingsDiagnostic] = []
        let bad = CmuxNextSettings.JSONValue.object(["sidebar": .object(["groupPinMark": .string("sparkles")])])
        #expect(SidebarSectionsSetting.parse(bad, diagnostics: &diagnostics).groupPinMark == .off)
        #expect(diagnostics.map(\.path) == ["sidebar.groupPinMark"])
    }

    @Test func theModelTakesTheSetting() {
        let model = SidebarModel(sections: [])
        var preferences = SidebarSectionsPreferences.defaults
        preferences.groupPinMark = .shelf
        model.applyListPreferences(preferences)
        #expect(model.groupPinMark == .shelf)
        #expect(preferences.changesList(from: .defaults), "a new look redraws the list")
    }

    /// Pinning a member where it already sits (the group's first member) moves no row: the daemon's live sections are
    /// the ones the rows show already. The pass that skips such a list must still show the document's new mark.
    @Test func aPinThatMovesNoRowStillReachesTheRows() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let previous = SidebarDocStore.current
        SidebarDocStore.current = store
        defer { SidebarDocStore.current = previous }
        let model = SidebarModel()
        model.docDrag = Fixture.drag
        let rows = SidebarRows(model: model)
        store.shown = Self.projection(pinned: false)
        rows.show(Fixture.raw(), creating: ([], nil), unlessShown: true)
        #expect(Self.pinned(model.sections)["ws-2"] == false)
        store.shown = Self.projection(pinned: true) // the same order: only the mark changed
        rows.show(Fixture.raw(), creating: ([], nil), unlessShown: true)
        #expect(Self.pinned(model.sections)["ws-2"] == true, "a pin in place never reached the rows")
    }
}
