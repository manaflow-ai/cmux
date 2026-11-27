@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import Foundation
import Testing

/// `sidebar.folderlessUngrouped` (customize-app-profiles, the Claude Code app's sidebar): under Group by Folder, rows
/// with no folder sit at the end of the list with no "No Folder" header. Off (the default) keeps the header.
@MainActor @Suite struct SidebarFolderlessUngroupedTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let section = SectionID.machine(.local)

    static func row(_ id: String, folder: String?) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id, lastActivity: Date(timeIntervalSince1970: 1_800_000_000))
        row.folder = folder
        return row
    }

    static func sections() -> [SidebarSection] {
        [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(row("loose1", folder: nil)), .workspace(row("a1", folder: "~/a")),
            .workspace(row("loose2", folder: nil)), .workspace(row("a2", folder: "~/a")),
        ])]
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }

    static func keys(ungrouped: Bool, by: SidebarGroupBy = .folder) -> [SidebarRowKey] {
        var preferences = SidebarSectionsPreferences.defaults
        preferences.groupBy = by
        preferences.folderlessUngrouped = ungrouped
        let model = SidebarModel(sections: sections())
        model.applyListPreferences(preferences)
        return SidebarLayout.make(sections: sections(), metrics: .standard, options: model.listOptions()).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    @Test func offKeepsTheNoFolderHeader() {
        #expect(Self.keys(ungrouped: false) == [
            .folder(Self.section, "~/a"), Self.w("a1"), Self.w("a2"),
            .folder(Self.section, ""), Self.w("loose1"), Self.w("loose2"),
        ])
    }

    @Test func onDrawsFolderlessRowsLastWithNoHeader() {
        #expect(Self.keys(ungrouped: true) == [
            .folder(Self.section, "~/a"), Self.w("a1"), Self.w("a2"), Self.w("loose1"), Self.w("loose2"),
        ])
    }

    @Test func onChangesNothingOutsideGroupByFolder() {
        #expect(Self.keys(ungrouped: true, by: .none) == Self.keys(ungrouped: false, by: .none))
    }

    @Test func theToggleRedrawsTheList() {
        var on = SidebarSectionsPreferences.defaults
        on.folderlessUngrouped = true
        #expect(on.changesList(from: .defaults))
    }
}
