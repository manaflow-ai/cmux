import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// Reopen / Delete Saved Tab Group… (verify/parity-mac.md, Tabs): what the phone reads from the
/// Mac's saved groups and which of them are open.
@Suite struct SavedTabGroupTests {
    static func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func savedGroupsAndWhichAreOpen() throws {
        let saved = try Self.object(#"""
        {"ok":true,"data":{"saved_groups":[
          {"id":"saved_a","room":"default","name":"Release","color":"orange","updated_at_ms":1,
           "members":[{"kind":"terminal","terminal_id":"t1","cwd":"/Users/x/p","title":"zsh"},
                      {"kind":"terminal","terminal_id":null,"cwd":null,"title":null},
                      {"kind":"browser","url":"https://example.com","engine":null,"profile_id":null,"title":"Docs"}]},
          {"id":"saved_b","room":"default","name":"","color":"green","updated_at_ms":2,"members":[]},
          {"name":"no id"}
        ]}}
        """#)
        let open = try Self.object(#"{"ok":true,"data":{"groups":[{"id":"tgrp_1","saved_id":"saved_b"},{"id":"tgrp_2","saved_id":null}]}}"#)
        let groups = LiveWorkspaceCreationBackend.savedTabGroups(saved: saved, open: open)
        #expect(groups == [
            SavedTabGroup(id: "saved_a", name: "Release", color: "orange", terminals: 2, browsers: 1, isOpen: false),
            SavedTabGroup(id: "saved_b", name: "", color: "green", isOpen: true),
        ])
        #expect(groups[0].summary == "2 terminals, 1 browser tab")
        #expect(groups[1].displayName == "Green group")
        #expect(groups[1].summary == "No tabs")
        // The bare data object (no envelope) reads the same.
        let bare = try Self.object(#"{"saved_groups":[{"id":"saved_c","name":"x","color":"red","members":[{"kind":"terminal"}]}]}"#)
        #expect(LiveWorkspaceCreationBackend.savedTabGroups(saved: bare, open: [:]).map(\.summary) == ["1 terminal"])
    }

    @Test func theMacsWords() {
        #expect(SavedTabGroupAction.reopen.title == "Reopen Saved Tab Group…")
        #expect(SavedTabGroupAction.delete.title == "Delete Saved Tab Group…")
        #expect(SavedTabGroupAction.reopen.sheetTitle == "Reopen Saved Tab Group")
    }

    /// Duplicate Workspace from a phone: each terminal again in its folder (the Mac's
    /// unabbreviated one when it reports it), each web page again; chats and non-web pages
    /// are left out.
    @Test func duplicatePlanFollowsTheTabs() {
        let tabs = [
            WorkspaceTab(id: "s1", kind: .terminal, title: "zsh", subtitle: "~/p"),
            WorkspaceTab(id: "s2", kind: .agent, title: "Claude"),
            WorkspaceTab(id: "s3", kind: .browser, title: "Docs", url: URL(string: "https://example.com/a")),
            WorkspaceTab(id: "s4", kind: .browser, title: "File", url: URL(string: "file:///etc/hosts")),
            WorkspaceTab(id: "s5", kind: .terminal, title: "build"),
        ]
        let ws = Workspace(id: "w", macID: "m", title: "api", directory: "~/p", tabs: tabs, lastActivityAt: Date())
        #expect(LiveWorkspaceCreationBackend.duplicatePlan(ws, directories: ["s1": "/Users/x/p"]) == [
            .terminal(folder: "/Users/x/p"), .browser(url: "https://example.com/a"), .terminal(folder: nil),
        ])
        // The folder is typed only when it can be (never home, never a line-editing character).
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/Users/x/p") == "cd '/Users/x/p' && clear\n")
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("~") == nil)
    }
}
