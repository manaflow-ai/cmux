import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileWorkspaceRemoteStateDecodeTests {
    @Test
    func decodesVersionedWorkspaceStateAndViewPresence() throws {
        let data = Data(#"""
        {
          "workspaces": [{
            "id": "workspace-1",
            "title": "Build",
            "is_selected": true,
            "remote_state": {
              "version": 1,
              "agents": [
                {"agent": "codex", "state": "needs_input", "panel_ids": ["panel-1"]},
                {"agent": "claude_code", "state": "idle"}
              ],
              "git": {"branch": "feat/hive", "is_dirty": true},
              "pull_request": {
                "number": 8082,
                "state": "open",
                "ci_status": "pending",
                "url": "https://github.com/manaflow-ai/cmux/pull/8082",
                "label": "PR",
                "branch": "feat/hive",
                "is_stale": false
              },
              "notifications": {
                "unread_count": 2,
                "has_unread": true,
                "latest_notification_id": "notification-1"
              }
            },
            "terminals": []
          }],
          "view_presence": {
            "version": 1,
            "views": [{
              "client_id": "phone-1",
              "connection_count": 2,
              "display_name": "Austin's iPhone",
              "kind": "ios"
            }]
          }
        }
        """#.utf8)

        let response = try MobileSyncWorkspaceListResponse.decode(data)
        let workspace = try #require(response.workspaces.first)
        let state = try #require(workspace.remoteState)
        #expect(state.version == 1)
        #expect(state.agents.count == 2)
        #expect(state.agents[0].state == .needsInput)
        #expect(state.agents[0].panelIDs == ["panel-1"])
        #expect(state.agents[1].panelIDs.isEmpty)
        #expect(state.git == MobileWorkspaceGitState(branch: "feat/hive", isDirty: true))
        #expect(state.pullRequest?.number == 8082)
        #expect(state.pullRequest?.state == .open)
        #expect(state.pullRequest?.ciStatus == .pending)
        #expect(state.pullRequest?.isStale == false)
        #expect(state.notifications.unreadCount == 2)
        #expect(state.notifications.latestNotificationID == "notification-1")

        let presence = try #require(response.viewPresence)
        #expect(presence.version == 1)
        #expect(presence.views.first?.clientID == "phone-1")
        #expect(presence.views.first?.connectionCount == 2)
        #expect(presence.views.first?.kind == "ios")
    }

    @Test
    func legacyWorkspaceListStillDecodesWithoutAdditiveState() throws {
        let data = Data(#"""
        {
          "workspaces": [{
            "id": "workspace-legacy",
            "title": "Legacy",
            "is_selected": false,
            "terminals": []
          }]
        }
        """#.utf8)

        let response = try MobileSyncWorkspaceListResponse.decode(data)
        #expect(response.groups.isEmpty)
        #expect(response.viewPresence == nil)
        #expect(response.workspaces.first?.remoteState == nil)
    }

    @Test
    func unknownLifecycleValuesDegradeWithoutBreakingTheWorkspaceList() throws {
        let data = Data(#"""
        {
          "workspaces": [{
            "id": "workspace-future",
            "title": "Future",
            "is_selected": false,
            "remote_state": {
              "version": 2,
              "agents": [{"agent": "future-agent", "state": "waiting_for_cloud"}],
              "git": null,
              "pull_request": {
                "number": 1,
                "state": "draft",
                "ci_status": "cancelled"
              },
              "notifications": {"unread_count": 0, "has_unread": false}
            },
            "terminals": []
          }]
        }
        """#.utf8)

        let state = try #require(MobileSyncWorkspaceListResponse.decode(data).workspaces.first?.remoteState)
        #expect(state.version == 2)
        #expect(state.agents.first?.state == .unknown)
        #expect(state.pullRequest?.state == .unknown)
        #expect(state.pullRequest?.ciStatus == .unknown)
    }
}
