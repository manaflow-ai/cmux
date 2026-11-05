import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

#if os(iOS)
/// Jump to Latest Unread and Jump to Last Prompt read what the Mac's tree and agent reports
/// already carry (`list-workspaces` markers with `created_at_ms`, `agent-changed`).
@MainActor @Suite struct TabAttentionLiveTests {
    @Test func latestUnreadIsTheNewestUnreadMarker() throws {
        let reply = Data("""
        {"ok":true,"data":{"workspaces":[
          {"id":1,"key":"ws-a","title":"a","screens":[{"id":1,"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[
            {"surface":1,"kind":"pty","title":"zsh","notification":{"notification":5,"unread":true,"created_at_ms":2000}},
            {"surface":2,"kind":"pty","title":"old","notification":{"notification":9,"unread":true,"created_at_ms":1000}},
            {"surface":3,"kind":"pty","title":"read","notification":{"notification":12,"unread":false,"created_at_ms":9000}}
          ]}]}]},
          {"id":2,"key":"ws-b","title":"b","screens":[{"id":2,"active":true,"active_pane":2,"panes":[{"id":2,"active_tab":0,"tabs":[
            {"surface":4,"kind":"pty","title":"new","notification":{"notification":7,"unread":true,"created_at_ms":3000}}
          ]}]}]}
        ]}}
        """.utf8)
        let tree = try DaemonTree(reply: reply, macID: "mac")
        #expect(tree.notificationMarkers[4]?.createdAt == Date(timeIntervalSince1970: 3))
        let place = try #require(LiveWorkspaceCreationBackend.latestUnread(in: tree))
        #expect(place.workspaceID == "ws-b" && place.tabID == "s4")
        let prompted = LiveWorkspaceCreationBackend.lastPrompted(in: tree, prompts: [1: Date(timeIntervalSince1970: 50), 2: Date(timeIntervalSince1970: 60)])
        #expect(prompted?.tabID == "s2")
        #expect(LiveWorkspaceCreationBackend.lastPrompted(in: tree, prompts: [:]) == nil)
    }

    /// The Mac's `AgentRoster.startsPromptedTurn`: starting work is a prompt; resuming from an
    /// approval is not; a repeated `working` with a new time is a new hook prompt.
    @Test func promptedTurnsFollowTheMacsRule() {
        let idle = AgentState(state: "idle", agent: "claude")
        let working = AgentState(state: "working", agent: "claude", updatedAt: Date(timeIntervalSince1970: 1))
        let later = AgentState(state: "working", agent: "claude", updatedAt: Date(timeIntervalSince1970: 2))
        #expect(WorkspaceSync.startsPromptedTurn(from: nil, to: working))
        #expect(WorkspaceSync.startsPromptedTurn(from: idle, to: working))
        #expect(!WorkspaceSync.startsPromptedTurn(from: AgentState(state: "blocked", agent: "claude"), to: working))
        #expect(!WorkspaceSync.startsPromptedTurn(from: working, to: working))
        #expect(WorkspaceSync.startsPromptedTurn(from: working, to: later))
        #expect(!WorkspaceSync.startsPromptedTurn(from: working, to: idle))
    }
}
#endif
