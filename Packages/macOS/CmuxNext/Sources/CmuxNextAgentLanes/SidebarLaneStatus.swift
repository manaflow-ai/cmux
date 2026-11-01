import CmuxNextAgentActivity
public import CmuxNextBridge
import CmuxNextDesign
import Foundation
public import CmuxNextSidebar

extension SidebarRowFeed {
    /// This feed as the mapping's row source, each row's activity merged with this Mac's acpmux
    /// lanes (`SidebarLaneStatus`, `sidebar.laneStatus`).
    @MainActor public var laneRowSource: SidebarMapping.RowSource {
        SidebarLaneStatus.applying(rowSource, lanes: .shared, turns: .shared, marks: .shared)
    }
}

/// Rows can show their agent sessions' acpmux lane state (`sidebar.laneStatus`, off by default):
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
    /// merged with its lanes, and its Priority chip (`sidebar.rowStatus`), and always its lanes'
    /// usage warnings (the row's warning badge). The toggles, the lanes and the read marks are read
    /// inside the row's mapping, so flipping a toggle, a lane change or a mark maps that row again.
    static func applying(_ rows: SidebarMapping.RowSource?, lanes: AgentLaneStore,
                         turns: AgentTurnStateStore, marks: AgentPriorityMarks = .shared) -> SidebarMapping.RowSource {
        { workspace, machine, make in
            let merged: SidebarRowFeed.Make = {
                var row = make()
                let mergesState = SidebarTunables.laneStatus.value, namesState = SidebarTunables.rowStatus.value
                let saysStep = SidebarTunables.nowLine.value
                let local = SidebarTunables.laneFixture.value ? SidebarLaneFixture.lanes(workspace)
                    : SidebarLocalLanes.lanes(workspace, lanes: lanes, turns: turns)
                // A runaway session's warning shows whatever the lane toggles say (Leo 2026-10-30).
                row.usageWarnings = usageWarnings(local)
                guard mergesState || namesState || saysStep else { return row }
                if mergesState { merge(local, into: &row) }
                if namesState { row.agentChip = chip(local, marks: marks.state) }
                if saysStep { row.agentStep = step(local) }
                return row
            }
            return rows?(workspace, machine, merged) ?? merged()
        }
    }

    /// `row` with the strongest of its own activity and `lanes`' states. A chat that asks for the
    /// user comes first, as in the Priority view (needs you, then failed): a failure beside it never
    /// turns the row's one yellow dot into the blue one (Leo 2026-10-21, "why ISN'T THIS JUST A
    /// YELLOW DOT!?"; the row draws no "Needs you" word to fall back on).
    static func merge(_ lanes: [AgentActivityLane], into row: inout SidebarWorkspace) {
        for lane in lanes {
            let state = indicator(lane.state)
            if state.isWorking { row.agentWorking = true }
            let current = StatusReport(id: "row", source: .explicit, state: row.activity)
            let precedes = switch (asks(state), asks(row.activity)) {
            case (true, false): true
            case (false, true): false
            default: StatusStack.precedes(StatusReport(id: "lane:\(lane.id)", source: .agent, state: state), current)
            }
            guard precedes else { continue }
            row.activity = state
            row.activityStyle = nil
            row.detail.activitySince = lane.since
        }
    }

    /// Whether `state` waits on the user (a question, a permission, a sign-in).
    private static func asks(_ state: StatusIndicatorState) -> Bool {
        if case .waiting = state { true } else { false }
    }

    /// The Priority view's chip for the most urgent of `lanes` (`AgentPriorityRanking`, with the
    /// same read marks and Red CI), nil when each one works, is idle or finished: the working mark
    /// already says working, and a row never says Done (Leo 2026-10-21; its unread dot does). A
    /// finished chat drops out before the ranking, so it never hides a failed one, and its failing
    /// checks still read as Red CI. `failingChecks` is the Red CI answer, by default the session tree feed's.
    static func chip(_ lanes: [AgentActivityLane], marks: AgentPriorityMarks.State,
                     failingChecks: ((AgentActivityLane) -> Bool)? = nil) -> SidebarPriorityEntry.State? {
        lanes.compactMap { lane -> SidebarPriorityEntry.State? in
            let failing = failingChecks?(lane) ?? SidebarSessionTreeFeed.shared.checksFailing(lane)
            switch AgentPriorityRanking.state(lane, read: marks.read[lane.id] == AgentPriorityMarks.stamp(lane), failingChecks: failing) {
            case .done: return failing ? .ciFailing : nil
            case .working, .idle: return nil
            case let state: return state
            }
        }
        .min { AgentPriorityRanking.tier($0) < AgentPriorityRanking.tier($1) }
    }

    /// Activity from the most recently started working lane that has any. acpmux derives
    /// lane.step from turn.prompt whenever it exists, then masks, folds and truncates it:
    /// comparing the strings would leak long prompts. Keep the opt-in Now line, using the
    /// turn's activity/plan instead, or the lane step only when it has no prompt source.
    static func step(_ lanes: [AgentActivityLane]) -> String? {
        func firstLine(_ text: String?) -> String? {
            text?.split(whereSeparator: \.isNewline).first
                .map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return lanes.filter { $0.state == .working }.compactMap { lane -> (Date, String)? in
            guard let text = firstLine(lane.turnActivity) ?? firstLine(lane.turnPlanStep)
                ?? (lane.turnPrompt == nil ? firstLine(lane.step) : nil) else { return nil }
            return (lane.since ?? .distantPast, text)
        }.max { $0.0 < $1.0 }?.1
    }

    /// Each usage warning of `lanes`, once, in lane order.
    static func usageWarnings(_ lanes: [AgentActivityLane]) -> [String] {
        var seen = Set<String>()
        return lanes.flatMap(\.usageWarnings).filter { seen.insert($0).inserted }
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
