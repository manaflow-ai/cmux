import Foundation
import Testing
@testable import CmuxMobileLive

/// The Mac's home workspace (`kind: "home"`, `workspace-kind-v1`) is what the
/// Mac sidebar's Home item shows, not a workspace row (`SidebarMapping`
/// filters `homeKind`). The phone has its own Home tab, so the home workspace
/// never becomes a Workspaces row, a search result or a count. The filter is
/// the kind, never the name: a renamed home stays out, a workspace the user
/// named "Home" stays in.
@Suite struct HomeWorkspaceTests {
    static let reply = Data("""
    {"ok":true,"data":{"workspace_revision":9,"workspaces":[
      {"id":1,"key":"ws-home","name":"Home","kind":"home","active":false,"unread_count":3,"screens":[
        {"id":1,"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[
          {"surface":11,"kind":"pty","title":"zsh","cwd":"/Users/me","notification":{"notification":4,"unread":true}}
        ]}]}
      ]},
      {"id":2,"key":"ws-1","name":"workspace-1","kind":"normal","screens":[
        {"id":2,"active":true,"active_pane":2,"panes":[{"id":2,"active_tab":0,"tabs":[
          {"surface":12,"kind":"pty","title":"zsh","cwd":"/Users/me/src"}
        ]}]}
      ]},
      {"id":3,"key":"ws-named-home","name":"Home","title":"Home","screens":[]},
      {"id":4,"key":"ws-renamed-home","name":"Inbox","title":"Inbox","kind":"home","screens":[]}
    ]}}
    """.utf8)

    @Test func homeKindIsNotAWorkspace() throws {
        let tree = try DaemonTree(reply: Self.reply, macID: "mac")
        #expect(tree.workspaces.map(\.id) == ["ws-1", "ws-named-home"])
        #expect(tree.homeWorkspaces.map(\.id) == ["ws-home", "ws-renamed-home"])
        // Its terminals stay known: an agent working there still reaches the Feed.
        #expect(tree.surfaces["s11"] == 11)
    }

    /// The Mac's home terminal is not a Workspaces row, but Codex working in it
    /// still reports to the phone's Feed (the Mac shows it under its Home item).
    @Test @MainActor func anAgentInTheHomeWorkspaceStillReachesTheFeed() async {
        let daemon = TerminalFeedTests.FakeDaemon()
        daemon.rows = [TerminalFeedTests.row("ntf_h", "Codex finished", surface: 11, at: 1_000_000)]
        let (store, feed) = TerminalFeedTests.make(daemon)
        feed.treeChanged(try! DaemonTree(reply: Self.reply, macID: "mac"), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { !store.items.isEmpty }
        #expect(store.items.map(\.id) == [TerminalFeed.itemID(macID: "mac", entry: "ntf_h")])
        #expect(store.items.first?.workspaceID == "ws-home")
    }

    @Test func olderDaemonsWithoutKindKeepEveryWorkspace() throws {
        let reply = Data("""
        {"ok":true,"data":{"workspaces":[{"id":1,"key":"a","name":"Home","screens":[]},{"id":2,"key":"b","name":"b","screens":[]}]}}
        """.utf8)
        #expect(try DaemonTree(reply: reply, macID: "mac").workspaces.map(\.id) == ["a", "b"])
    }
}
