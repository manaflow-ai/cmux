import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// Each sidebar row's agent sessions (`SidebarAgentLink`), for Group by Status's elbow children:
/// the acpmux lanes (`AgentLaneStore`, from `_acpmux/watch`) of the workspace's agent chat tabs on
/// this Mac. A lane's `parent` is its session's `mux.parent` tag, the coordinator session's name.
@MainActor
enum SidebarAgentLinks {
    /// `rows` (the row feed's source, else the mapping itself) with each mapped row's link set.
    static func linking(_ rows: SidebarMapping.RowSource?, lanes: AgentLaneStore = .shared,
                        turns: AgentTurnStateStore = .shared) -> SidebarMapping.RowSource {
        { workspace, machine, make in rows?(workspace, machine, make) ?? make() }
    }
}
