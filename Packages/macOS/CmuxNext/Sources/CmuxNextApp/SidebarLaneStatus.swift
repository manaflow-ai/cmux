import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextSidebar

/// Rows show their agent sessions' acpmux lane state (`sidebar.laneStatus`, Debug, off by default).
@MainActor
enum SidebarLaneStatus {
    /// `rows` (the row feed's source, else the mapping itself) with each mapped row's activity
    /// merged with its lanes.
    static func applying(_ rows: SidebarMapping.RowSource?, lanes: AgentLaneStore = .shared,
                         turns: AgentTurnStateStore = .shared) -> SidebarMapping.RowSource {
        { workspace, machine, make in rows?(workspace, machine, make) ?? make() }
    }
}
