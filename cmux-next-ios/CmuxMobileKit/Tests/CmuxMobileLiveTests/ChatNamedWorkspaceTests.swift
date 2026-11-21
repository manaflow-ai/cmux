import Foundation
import Testing
@testable import CmuxMobileLive

/// An unnamed workspace whose front tab is an agent chat reads as the chat on the phone, as
/// the Mac's sidebar row does (`WorkspaceAutoNameReader`), never as the daemon's `workspace-N`
/// (Leo, 2026-11-05: "this workspace didn't inherit the agent chat name"). The chat's tab
/// reads as its title too, not just "Claude".
@Suite struct ChatNamedWorkspaceTests {
    static let reply = Data("""
    {"ok":true,"data":{"workspace_revision":3,"workspaces":[
      {"id":347,"key":"ws-347","name":"workspace-347","screens":[
        {"id":1,"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[
          {"surface":11,"kind":"conversation","title":"","conversation":{"agent_session":{"session":"sess-a","harness":"claude"}}}
        ]}]}
      ]},
      {"id":2,"key":"ws-renamed","name":"workspace-2","title":"Release","screens":[
        {"id":2,"active":true,"active_pane":2,"panes":[{"id":2,"active_tab":0,"tabs":[
          {"surface":12,"kind":"conversation","title":"","conversation":{"agent_session":{"session":"sess-b","harness":"claude"}}}
        ]}]}
      ]},
      {"id":3,"key":"ws-own-name","name":"api","screens":[
        {"id":3,"active":true,"active_pane":3,"panes":[{"id":3,"active_tab":0,"tabs":[
          {"surface":13,"kind":"conversation","title":"","conversation":{"agent_session":{"session":"sess-c","harness":"claude"}}}
        ]}]}
      ]},
      {"id":4,"key":"ws-named-tab","name":"workspace-4","screens":[
        {"id":4,"active":true,"active_pane":4,"panes":[{"id":4,"active_tab":0,"tabs":[
          {"surface":14,"kind":"conversation","name":"Triage","title":"","conversation":{"agent_session":{"session":"sess-d","harness":"claude"}}}
        ]}]}
      ]},
      {"id":5,"key":"ws-shell","name":"workspace-5","screens":[
        {"id":5,"active":true,"active_pane":5,"panes":[{"id":5,"active_tab":0,"tabs":[
          {"surface":15,"kind":"pty","title":"zsh","cwd":"/Users/me"}
        ]}]}
      ]}
    ]}}
    """.utf8)

    static func agents(_ titles: [String: String]) -> AgentStates {
        var agents = AgentStates()
        agents.chatTitles = titles
        return agents
    }

    @Test func anUnnamedWorkspaceTakesItsChatsTitle() throws {
        let tree = try DaemonTree(reply: Self.reply, macID: "mac", agents: Self.agents([
            "sess-a": "can u try doing the workflow here\nand more", "sess-b": "B", "sess-c": "C", "sess-d": "D",
        ]))
        let byID = Dictionary(uniqueKeysWithValues: tree.workspaces.map { ($0.id, $0) })
        #expect(byID["ws-347"]?.title == "can u try doing the workflow here")
        #expect(byID["ws-347"]?.hasCustomTitle == false)
        #expect(byID["ws-347"]?.tabs.first?.title == "can u try doing the workflow here")
        // A name the person gave the workspace or the tab, or the workspace's own name, still wins.
        #expect(byID["ws-renamed"]?.title == "Release")
        #expect(byID["ws-own-name"]?.title == "api")
        #expect(byID["ws-named-tab"]?.title == "workspace-4")
        #expect(byID["ws-named-tab"]?.tabs.first?.title == "Triage")
        #expect(byID["ws-shell"]?.title == "workspace-5")
    }

    @Test func aChatWithNoTitleYetKeepsTheDaemonsName() throws {
        let tree = try DaemonTree(reply: Self.reply, macID: "mac")
        let row = try #require(tree.workspaces.first { $0.id == "ws-347" })
        #expect(row.title == "workspace-347")
        #expect(row.tabs.first?.title == "Claude")
    }

    /// A title that arrives after the tree was read renames the row: the projection republishes it.
    @Test func aTitleThatArrivesLaterRepublishesTheRow() async throws {
        let projection = WorkspaceProjection()
        try await projection.reset(snapshot: Self.reply, macID: "mac")
        let update = try #require(try await projection.updateAgents(agents: Self.agents(["sess-a": "Fix the build"]), activity: [:]))
        #expect(update.tree.workspaces.first { $0.id == "ws-347" }?.title == "Fix the build")
    }
}
