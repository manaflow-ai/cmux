import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// Each sidebar row's agent sessions (`SidebarAgentLink`), for Group by Status's elbow children:
/// the acpmux lanes (`AgentLaneStore`, from `_acpmux/watch`) of the workspace's agent chat tabs on
/// this Mac. A lane's `parent` is its session's `mux.parent` tag, the coordinator session's name;
/// `SidebarRows` resolves it to the workspace showing that session (`SidebarAgentLink.linking`).
/// Every harness's chats are acpmux sessions, so no brand decides anything here.
@MainActor
enum SidebarAgentLinks {
    /// Whether rows nest under their parents (Debug `sidebar.groupByStatus` and `sidebar.statusElbow`).
    /// Off, nothing reads a lane: rows map as before and a lane change maps no row (review of #20905).
    static var nests: Bool { SidebarTunables.groupByStatus.value && SidebarTunables.statusElbow.value }

    /// `rows` (the row feed's source, else the mapping itself) with each mapped row's link set, or
    /// `rows` as is while rows do not nest. The link is read inside the row's mapping, so a lane
    /// change maps that row again.
    static func linking(_ rows: SidebarMapping.RowSource?, lanes: AgentLaneStore = .shared,
                        turns: AgentTurnStateStore = .shared) -> SidebarMapping.RowSource? {
        guard nests else { return rows }
        return { workspace, machine, make in
            let linked: SidebarRowFeed.Make = {
                var row = make()
                row.agentLink = link(workspace, lanes: lanes, turns: turns)
                return row
            }
            return rows?(workspace, machine, linked) ?? linked()
        }
    }

    /// The names of the acpmux sessions `workspace`'s chat tabs on this Mac show, in tab order,
    /// and the first one's coordinator; nil when no tab shows a session acpmux knows a lane for.
    static func link(_ workspace: WorkspaceModel, lanes: AgentLaneStore, turns: AgentTurnStateStore) -> SidebarAgentLink? {
        var link = SidebarAgentLink()
        for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
            guard let ref = tab.agentSession, let session = ref.session, let host = turns.localHost, ref.host == host,
                  let lane = lanes.lanes[session], lane.peer == nil else { continue }
            link.names.append(lane.name)
            if link.parent == nil { link.parent = lane.parent }
        }
        return link.names.isEmpty ? nil : link
    }
}
