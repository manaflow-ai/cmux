import CmuxNextAgentActivity
public import CmuxNextBridge
import CmuxNextDesign
public import CmuxNextSidebar

extension SidebarRowFeed {
    /// This feed as the mapping's row source, each row's activity merged with this Mac's acpmux
    /// lanes (`SidebarLaneStatus`, `sidebar.laneStatus`).
    @MainActor public var laneRowSource: SidebarMapping.RowSource {
        SidebarLaneStatus.applying(rowSource, lanes: .shared, turns: .shared, marks: .shared)
    }
}

/// Rows show their agent sessions' acpmux lane state (`sidebar.laneStatus`, Debug, on by default):
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
    /// merged with its lanes, and its Priority chip (`sidebar.rowStatus`). The toggles, the lanes
    /// and the read marks are read inside the row's mapping, so flipping a toggle, a lane change or
    /// a mark maps that row again; with both toggles off no lane is read.
    static func applying(_ rows: SidebarMapping.RowSource?, lanes: AgentLaneStore,
                         turns: AgentTurnStateStore, marks: AgentPriorityMarks = .shared) -> SidebarMapping.RowSource {
        { workspace, machine, make in
            let merged: SidebarRowFeed.Make = {
                var row = make()
                let mergesState = SidebarTunables.laneStatus.value, namesState = SidebarTunables.rowStatus.value
                guard mergesState || namesState else { return row }
                let local = SidebarTunables.laneFixture.value ? SidebarLaneFixture.lanes(workspace)
                    : SidebarLocalLanes.lanes(workspace, lanes: lanes, turns: turns)
                if mergesState { merge(local, into: &row) }
                if namesState { row.agentChip = chip(local, marks: marks.state) }
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

    /// The Priority view's chip for the most urgent of `lanes` (`AgentPriorityRanking`, with the
    /// same read marks), nil when each one works or is idle: the working mark already says working.
    static func chip(_ lanes: [AgentActivityLane], marks: AgentPriorityMarks.State) -> SidebarPriorityEntry.State? {
        lanes.map { AgentPriorityRanking.state($0, read: marks.read[$0.id] == AgentPriorityMarks.stamp($0)) }
            .filter { if case .working = $0 { false } else { $0 != .idle } }
            .min { AgentPriorityRanking.tier($0) < AgentPriorityRanking.tier($1) }
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
