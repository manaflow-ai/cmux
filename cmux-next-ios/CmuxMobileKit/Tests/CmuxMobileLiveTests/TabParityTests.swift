import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// Parity round 2 (verify/parity-mac.md, Tabs): what the phone reads from the Mac's tree for
/// pins and tab groups, and the names and colors it sends as the Mac would.
@Suite struct TabParityTests {
    static let reply = Data(#"""
    {"ok":true,"data":{"workspaces":[
      {"id":7,"key":"ws_a","name":"a","kind":"home","screens":[{"active":true,"active_pane":3,"panes":[{"id":3,"active_tab":0,
        "tab_groups":[{"id":"tgrp_1","name":"Review","color":"green","collapsed":false,"saved_id":"sav_1","start":1,"count":1,"surfaces":[12]}],
        "tabs":[{"surface":11,"kind":"pty","title":"zsh","pinned":true,"group":null,"cwd":"/Users/x/p"},
                {"surface":12,"kind":"browser","title":"Docs","url":"https://example.com","pinned":false,"group":"tgrp_1"}]}]}]},
      {"id":9,"key":"ws_b","name":"b","screens":[{"active":true,"active_pane":4,"panes":[{"id":4,"active_tab":0,
        "tabs":[{"surface":13,"kind":"pty","title":"zsh"}]}]}]}
    ]}}
    """#.utf8)

    @Test func pinsGroupsAndWorkspaceNumbers() throws {
        let tree = try DaemonTree(reply: Self.reply, macID: "m")
        // Home (`kind: "home"`) is kept out of the workspace rows (`homeWorkspaces`), with its tabs.
        let home = try #require(tree.homeWorkspaces.first)
        let tabs = home.tabs
        #expect(tabs[0].isPinned && tabs[0].group == nil)
        #expect(!tabs[1].isPinned)
        #expect(tabs[1].group == WorkspaceTab.TabGroupRef(id: "tgrp_1", name: "Review", color: "green", isSaved: true))
        #expect(tree.workspaces[0].tabs[0].pinned == nil)
        #expect(tree.workspaceNumbers == ["ws_a": 7, "ws_b": 9])
        #expect(tree.groupPanes == ["tgrp_1": 3])
        #expect(home.isHome && !tree.workspaces[0].isHome)
    }

    @Test func groupNamesReadAsTheMacShowsThem() {
        #expect(WorkspaceTab.TabGroupRef(id: "g", name: "", color: "red").displayName == "Red group")
        #expect(WorkspaceTab.TabGroupRef(id: "g", name: "Build", color: "red").displayName == "Build")
        #expect(WorkspaceTab.TabGroupRef(id: "g", name: " ", color: "#112233").displayName == "Tab group")
    }

    /// The Mac's `GroupColor.automatic`: never blue or grey; grey once all are used.
    @Test func nextGroupColor() {
        #expect(WorkspaceTab.TabGroupRef.nextColor(used: []) == "red")
        #expect(WorkspaceTab.TabGroupRef.nextColor(used: ["red", "green"]) == "yellow")
        #expect(WorkspaceTab.TabGroupRef.nextColor(used: ["red", "green", "yellow", "purple", "cyan", "orange", "pink"]) == "grey")
    }

    /// The Mac's `NewWorkspaceName` for Move Tab to New Workspace.
    @Test func newWorkspaceNames() {
        let ws = { (title: String, tabs: [WorkspaceTab]) in Workspace(id: "w", macID: "m", title: title, directory: "~", tabs: tabs, lastActivityAt: Date()) }
        let shell = WorkspaceTab(id: "s1", kind: .terminal, title: "zsh", subtitle: "~/Development/cmux")
        let named = WorkspaceTab(id: "s2", kind: .terminal, title: "build")
        let page = WorkspaceTab(id: "s3", kind: .browser, title: "Browser", url: URL(string: "https://www.example.com/a"))
        let other = WorkspaceTab(id: "s4", kind: .terminal, title: "x")
        #expect(LiveWorkspaceCreationBackend.newWorkspaceName(for: shell, in: ws("w", [shell, other])) == "cmux")
        #expect(LiveWorkspaceCreationBackend.newWorkspaceName(for: named, in: ws("w", [named, other])) == "build")
        #expect(LiveWorkspaceCreationBackend.newWorkspaceName(for: page, in: ws("w", [page, other])) == "example.com")
        // The last tab keeps its workspace's own name, unless that is the daemon's default.
        #expect(LiveWorkspaceCreationBackend.newWorkspaceName(for: named, in: ws("api", [named])) == "api")
        #expect(LiveWorkspaceCreationBackend.newWorkspaceName(for: named, in: ws("workspace-4", [named])) == "build")
    }
}
