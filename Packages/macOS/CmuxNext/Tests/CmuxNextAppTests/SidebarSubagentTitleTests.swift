@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-30: "the sidebar tab shouldn't just be named claude sr2 coord if you can just say it's
/// SUbagent of sr2 coord". A session another one started, whose own title is its parent's name,
/// reads "Subagent of <parent>"; a child with a name of its own keeps it.
@MainActor @Suite struct SidebarSubagentTitleTests {
    @Test func aChildNamedLikeItsParentSaysWhoseItIs() {
        let parent = SidebarWorkspace(id: WorkspaceID("p"), title: "claude-sr2-coord")
        let twin = SidebarWorkspace(id: WorkspaceID("c"), title: " Claude-SR2-Coord ")
        let named = SidebarWorkspace(id: WorkspaceID("n"), title: "Fix login redirect")
        var o = SidebarLayoutOptions()
        o.sessionTree = SidebarSessionTreeState(parents: [twin.id: parent.id, named.id: parent.id])
        o.parentTitles = SidebarLayout.parentTitles(o.sessionTree!.parents, workspaces: [parent, twin, named])
        #expect(o.parentTitles == [twin.id: "claude-sr2-coord", named.id: "claude-sr2-coord"])
        #expect(o.rowContent(twin, machine: nil).subagentOf == "claude-sr2-coord")
        #expect(o.rowContent(named, machine: nil).subagentOf == nil)
        #expect(o.rowContent(parent, machine: nil).subagentOf == nil)
        #expect(Strings.subagentOf("claude-sr2-coord") == "Subagent of claude-sr2-coord")
    }

    @Test func aParentOutsideTheListGivesNoTitle() {
        let child = SidebarWorkspace(id: WorkspaceID("c"), title: "x")
        #expect(SidebarLayout.parentTitles([child.id: WorkspaceID("gone")], workspaces: [child]).isEmpty)
        #expect(SidebarLayout.parentTitles([:], workspaces: [child]).isEmpty)
    }
}
