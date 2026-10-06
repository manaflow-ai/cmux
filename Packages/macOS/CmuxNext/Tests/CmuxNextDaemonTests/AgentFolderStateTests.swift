import Foundation
import Testing
@testable import CmuxNextDaemon

/// The workspace's agent folder (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE, `workspace.agent_folder.set`):
/// the daemon's `extra.agent_folder` reaches the mirror and the workspace record, from a snapshot
/// and from an upsert, and an upsert without it clears it.
@MainActor @Suite struct AgentFolderStateTests {
    nonisolated static let workspace = SessionStateTests.workspace

    nonisolated static func snapshot(_ extra: String) -> String {
        SessionStateTests.item(#"""
        {"kind":"snapshot","cursor":{"generation":"g","revision":"4"},"reset_reason":"initial","snapshot":{
          "workspaces":[{"id":"\#(workspace)","session_id":"session_s","name":"beta","index":0,"focused":true,"extra":\#(extra)}],
          "screens":[],"panes":[],"tabs":[],"terminals":[],
          "browsers":[],"clients":[],"notifications":[],"agents":[],"frontend_projections":[],"sidebar_views":[],
          "cursor":{"generation":"g","revision":"4"},
          "extra":{"state":{"closed":[],"workspace_status":[],"screen_groups":[]}}
        }}
        """#)
    }

    nonisolated static func upsert(_ extra: String) -> String {
        SessionStateTests.item(#"""
        {"kind":"delta","cursor":{"generation":"g","revision":"6"},"previous_revision":"4","revision":"6","changes":[
          {"kind":"upsert","sequence":0,"resource":"workspace","id":"\#(workspace)","value":{"id":"\#(workspace)","session_id":"session_s","name":"beta","index":0,"focused":true,"extra":\#(extra)}}
        ]}
        """#)
    }

    private func event(_ line: String) -> DaemonEvent {
        DaemonEvent.decode(name: LineTransport.streamEvent, line: Data(line.utf8))
    }

    @Test func theAgentFolderDecodesIntoTheMirror() {
        guard case .sessionState(.snapshot(let mirror)) = event(Self.snapshot(#"{"agent_folder":"/Users/me/project"}"#)) else {
            Issue.record("not a snapshot")
            return
        }
        #expect(mirror.agentFolders[ResourceID(rawValue: Self.workspace)] == "/Users/me/project")
        var state = mirror
        state.apply(.workspace(ResourceID(rawValue: Self.workspace), ephemeral: false, agentFolder: nil))
        #expect(state.agentFolders.isEmpty)
    }

    @Test func theWorkspaceRecordShowsTheFolderAndLosesItWhenCleared() throws {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: event(Self.snapshot("{}")))])
        let workspace = try #require(store.workspaces.first { $0.resourceID?.rawValue == Self.workspace })
        #expect(workspace.agentFolder == nil)
        store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: event(Self.upsert(#"{"agent_folder":"/Users/me/project"}"#)))])
        #expect(workspace.agentFolder == "/Users/me/project")
        store.apply(batch: [DaemonEventEnvelope(sequence: 3, event: event(Self.upsert("{}")))])
        #expect(workspace.agentFolder == nil)
    }
}
