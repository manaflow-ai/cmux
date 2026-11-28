public import CmuxNextAgentActivity
public import CmuxNextBridge
public import CmuxNextDaemon

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

public extension AgentLaneStore {
    /// Whether a workspace still has a live local acpmux session. A purged
    /// session can leave its conversation tab in the daemon tree for a short
    /// time; it must not keep a sidebar row alive. While the watch is down,
    /// the sessions it listed last (`beforeGap`) count as live until the next
    /// complete page, so a transport gap never hides live work and never shows
    /// a gone session's workspace again (ask-71821f1cda). Before the first
    /// page every row stays.
    func keepsWorkspace(_ workspace: WorkspaceModel, turns: AgentTurnStateStore) -> Bool {
        let gap = live ? nil : beforeGap
        guard live || gap != nil, let host = turns.localHost else { return true }
        // One walk, no flattened copies. A workspace can mix a stale local agent tab with a live terminal or a
        // remote agent tab: only purge a row when every tab is a local agent ref; otherwise there is still content
        // this row must represent. No tabs: nothing to judge, it stays.
        var localSessions: [String] = []
        for screen in workspace.screens {
            for pane in screen.panes {
                for tab in pane.tabs {
                    guard let ref = tab.agentSession, ref.host == host, let session = ref.session else { return true }
                    localSessions.append(session)
                }
            }
        }
        guard !localSessions.isEmpty else { return true }
        if let gap { return localSessions.contains { gap.contains($0) } }
        return localSessions.contains { sessionIsLive($0) }
    }
}
