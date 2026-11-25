import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Group by None / Group by Folder in the Workspaces list, as the Mac's sidebar buckets its loose
/// rows (`SidebarLayout.folderBuckets`, `SidebarFolderTitle`).
@Suite struct WorkspaceListGroupingTests {
    private func row(_ id: String, _ folder: String, mac: String = "m") -> Workspace {
        Workspace(id: id, macID: mac, title: id, directory: folder, tabs: [], lastActivityAt: Date())
    }

    @Test func foldersInFirstSeenOrderWithNoFolderLast() {
        let buckets = WorkspaceListGrouping.buckets([row("a", ""), row("b", "~/src/app"), row("c", "~"), row("d", "~/src/app")])
        #expect(buckets.map(\.folder) == ["~/src/app", "~", ""])
        #expect(buckets[0].workspaces.map(\.id) == ["b", "d"])
        #expect(buckets.map { WorkspaceListGrouping.title($0.folder) } == ["app", "~", "No Folder"])
    }

    /// The Mac's groups stay as they are; every loose row goes under its folder after them.
    @Test func groupByFolderKeepsGroupsThenBucketsTheLooseRows() {
        let red = MacWorkspaceGroup(id: "grp_r", name: "Red", color: "red")
        let sections = [
            RecentSection(macID: "m", group: nil, workspaces: [row("a", "~/x")]),
            RecentSection(macID: "m", group: red, workspaces: [row("g", "~/y")]),
            RecentSection(macID: "m", group: nil, workspaces: [row("b", "~/y"), row("c", "~/x")], ordinal: 1),
        ]
        let none = WorkspaceListGrouping.arrange(sections, by: .none)
        #expect(none.map(\.id) == sections.map(\.id))
        #expect(none.allSatisfy { $0.folder == nil })
        let folder = WorkspaceListGrouping.arrange(sections, by: .folder)
        #expect(folder.map { $0.group?.id ?? $0.folder ?? "-" } == ["grp_r", "~/x", "~/y"])
        #expect(folder[1].workspaces.map(\.id) == ["a", "c"])
        #expect(folder[2].workspaces.map(\.id) == ["b"])
    }

    /// A list in the phone's own order (several Macs, no Mac order) stays flat.
    @Test func aListWithoutMacOrderIsNotBucketed() {
        let flat = [RecentSection(macID: "", group: nil, workspaces: [row("a", "~/x"), row("b", "~/y", mac: "n")])]
        let arranged = WorkspaceListGrouping.arrange(flat, by: .folder)
        #expect(arranged.count == 1 && arranged[0].folder == nil)
        #expect(WorkspaceListGrouping.folder.title == "Group by Folder")
    }
}
