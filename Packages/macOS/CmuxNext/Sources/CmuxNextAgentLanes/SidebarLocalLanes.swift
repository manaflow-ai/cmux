import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextDaemon

/// The acpmux lanes (`AgentLaneStore`, from `_acpmux/watch`) of a workspace's agent chat tabs on
/// this Mac: a chat whose session lives on this Mac's acpmux (`turns.localHost`) and whose lane
/// acpmux keeps here, not a mirrored peer's. Every harness's chats are acpmux sessions, so no
/// brand decides anything here. Read inside a row's mapping, so a change of one of the row's own
/// lanes maps that row again, and another session's change does not (`AgentLaneStore.lane(_:)`).
@MainActor
enum SidebarLocalLanes {
    /// `workspace`'s lanes in tab order; empty when no tab shows a session acpmux knows a lane for.
    static func lanes(_ workspace: WorkspaceModel, lanes: AgentLaneStore, turns: AgentTurnStateStore) -> [AgentActivityLane] {
        guard let host = turns.localHost else { return [] }
        return workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
            guard let ref = tab.agentSession, let session = ref.session, ref.host == host,
                  let lane = lanes.lane(session), lane.peer == nil else { return nil }
            return lane
        }
    }
}
