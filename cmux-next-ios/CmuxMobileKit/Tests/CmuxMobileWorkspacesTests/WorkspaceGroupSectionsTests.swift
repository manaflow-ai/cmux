import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// The Mac's workspace groups in the list: each group's members under its
/// header, in the Mac's order; Move Up / Down stays inside the group.
@Suite struct WorkspaceGroupSectionsTests {
    let macs = [MacDevice(id: "m", name: "Studio", isOnline: true)]
    let red = MacWorkspaceGroup(id: "grp_r", name: "Red", color: "red")
    let blue = MacWorkspaceGroup(id: "grp_b", name: "Blue", color: "blue", isCollapsed: true)

    private func ws(_ id: String, index: Int?, group: MacWorkspaceGroup? = nil, waiting: Bool = false) -> Workspace {
        var w = Workspace(id: id, macID: "m", title: id, directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 1000),
                          needsAttention: waiting)
        w.sidebarIndex = index
        w.group = group
        return w
    }

    @Test func groupsAreRunsInTheMacsOrder() {
        let inbox = WorkspaceInbox(scope: .all, macs: macs, workspaces: [
            ws("e", index: 5, group: blue), ws("a", index: 0), ws("b", index: 1, group: red), ws("c", index: 2, group: red),
            ws("d", index: 3), ws("f", index: 6, group: blue, waiting: true),
        ])
        #expect(inbox.recentSections.map { $0.group?.id } == [nil, "grp_r", nil, "grp_b"])
        #expect(inbox.recentSections.map { $0.workspaces.map(\.id) } == [["a"], ["b", "c"], ["d"], ["e"]])
        #expect(inbox.recentSections[3].group?.isCollapsed == true)
        // Inside its group only; a loose row moves among the loose rows.
        #expect(inbox.macOrder(of: inbox.recent[1]).map(\.id) == ["b", "c"])
        #expect(inbox.macOrder(of: inbox.recent[0]).map(\.id) == ["a", "d"])
        #expect(Set(inbox.recentSections.map(\.id)).count == 4)
    }

    /// Without the Mac's order the rows are newest first and show no groups.
    @Test func noGroupsWithoutTheMacsOrder() {
        let inbox = WorkspaceInbox(scope: .all, macs: macs, workspaces: [ws("a", index: nil, group: red), ws("b", index: nil)])
        #expect(inbox.recentSections.count == 1)
        #expect(inbox.recentSections[0].group == nil)
    }
}
