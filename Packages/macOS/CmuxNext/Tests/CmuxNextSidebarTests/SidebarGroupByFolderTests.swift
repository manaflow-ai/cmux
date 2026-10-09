import AppKit
import Testing
@testable import CmuxNextSidebar

/// Leo (2026-10-06): Group by Folder in the Projects menu buckets the loose
/// workspaces under a header per folder (the front tab's cwd). Your groups
/// stay above the folders; rows keep their model indices.
@MainActor @Suite struct SidebarGroupByFolderTests {
    private let local = SidebarMachine(id: .local, name: "Local", kind: .local)

    private func ws(_ name: String, _ folder: String?) -> SidebarWorkspace {
        var row = w(name)
        row.folder = folder
        return row
    }

    private func sections() -> [SidebarSection] {
        [SidebarSection(kind: .machine(local), nodes: [
            .workspace(ws("a", "~/src/app")),
            .group(SidebarGroup(id: GroupID("g"), name: "Work", color: .blue, workspaces: [w("b")])),
            .workspace(ws("c", "~/src/site")),
            .workspace(ws("d", "~/src/app")),
            .workspace(ws("e", nil)),
        ])]
    }

    private func layout(byFolder: Bool) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.showsSoleMachineHeader = true
        options.groupsByFolder = byFolder
        return SidebarLayout.make(sections: sections(), metrics: .standard, options: options)
    }

    @Test func looseRowsSortUnderTheirFolders() {
        let section = SectionID.machine(.local)
        let rows = layout(byFolder: true).rows
        #expect(rows.map(\.key) == [
            .section(section), .group(GroupID("g")), .workspace(id("b")),
            .folder(section, "~/src/app"), .workspace(id("a")), .workspace(id("d")),
            .folder(section, "~/src/site"), .workspace(id("c")),
            .folder(section, ""), .workspace(id("e")),
        ])
        // Each folder counts its rows; workspaces keep their model index.
        #expect(rows[3].childCount == 2 && rows[6].childCount == 1)
        #expect(rows[5].siblingIndex == 3 && rows[7].siblingIndex == 2)
        #expect(rows.map(\.y) == rows.map(\.y).sorted())
    }

    @Test func noneKeepsTheModelOrder() {
        let keys = layout(byFolder: false).rows.map(\.key)
        #expect(!keys.contains { if case .folder = $0 { true } else { false } })
        #expect(keys.suffix(6) == [.workspace(id("a")), .group(GroupID("g")), .workspace(id("b")),
                                   .workspace(id("c")), .workspace(id("d")), .workspace(id("e"))])
    }

    @Test func theFolderTitleIsItsLastComponent() {
        #expect(SidebarFolderTitle.title("~/src/app") == "app")
        #expect(SidebarFolderTitle.title("~") == "~")
        #expect(SidebarFolderTitle.title("/") == "/")
        #expect(SidebarFolderTitle.title("") == Strings.noFolder)
    }

    @Test func groupingByFolderFollowsTheSettingAndLocksReorder() {
        let model = SidebarModel(sections: sections())
        #expect(!model.listOptions().groupsByFolder && !model.locksReorder)
        model.groupsByFolder = true
        #expect(model.listOptions().groupsByFolder && model.locksReorder)
        #expect(model.itemOrder.rows == [.workspace(id("b")), .workspace(id("a")), .workspace(id("d")),
                                         .workspace(id("c")), .workspace(id("e"))])
    }
}
