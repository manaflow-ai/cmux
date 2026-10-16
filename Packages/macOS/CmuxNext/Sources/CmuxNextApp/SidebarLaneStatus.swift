import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar

/// Rows show their agent sessions' acpmux lane state (`sidebar.laneStatus`, Debug, off by default):
/// a row's status mark also follows the lane (`AgentLaneStore`) of each agent chat in it on this
/// Mac (`SidebarLocalLanes`), so it reads working, waiting on you or failed even when no turn
/// state reached the row, whatever harness runs the chat.
///
/// Precedence (`StatusStack`'s state rank): failed, then waiting on you, from either the row or a
/// lane; then working; then the row's own done; an idle lane adds nothing. The row's own state
/// wins a tie and keeps its style.
@MainActor
enum SidebarLaneStatus {
    /// `rows` (the row feed's source, else the mapping itself) with each mapped row's activity
    /// merged with its lanes. The toggle and the lanes are read inside the row's mapping, so
    /// flipping the toggle or a lane change maps that row again; with the toggle off no lane is read.
    static func applying(_ rows: SidebarMapping.RowSource?, lanes: AgentLaneStore = .shared,
                         turns: AgentTurnStateStore = .shared) -> SidebarMapping.RowSource {
        { workspace, machine, make in
            let merged: SidebarRowFeed.Make = {
                var row = make()
                guard SidebarTunables.laneStatus.value else { return row }
                merge(SidebarLocalLanes.lanes(workspace, lanes: lanes, turns: turns), into: &row)
                return row
            }
            return rows?(workspace, machine, merged) ?? merged()
        }
    }

    /// `row` with the strongest of its own activity and `lanes`' states.
    static func merge(_ lanes: [AgentActivityLane], into row: inout SidebarWorkspace) {
        for lane in lanes {
            let state = indicator(lane.state)
            if state.isWorking { row.agentWorking = true }
            let current = StatusReport(id: "row", source: .explicit, state: row.activity)
            guard StatusStack.precedes(StatusReport(id: "lane:\(lane.id)", source: .agent, state: state), current) else { continue }
            row.activity = state
            row.activityStyle = nil
            row.detail.activitySince = lane.since
        }
    }

    /// A lane state as the row's status mark.
    static func indicator(_ state: AgentActivityLane.State) -> StatusIndicatorState {
        switch state {
        case .working: .working
        case .input: .waiting
        case .failed, .lost: .error
        case .idle: .idle
        }
    }
}
