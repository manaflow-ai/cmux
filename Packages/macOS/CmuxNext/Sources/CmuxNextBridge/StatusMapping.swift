public import CmuxNextDaemon
public import CmuxNextDesign
public import CmuxNextTabs

/// Turns the status facts the daemon publishes about a tab into
/// `StatusReport`s, and merges them per tab and per workspace with
/// `StatusStack` (plans/cmux-next/status-indicators.md). The app only
/// renders: every fact here is written by its owner (agent hooks through
/// the session host today; `workspace_status` entries, OSC 9;4 terminal
/// progress and running commands once the daemon publishes them).
public struct StatusMapping {
    public static let shared = Self()

    /// The local acpmux turn states (agent chat tabs).
    let turns: AgentTurnStateStore
    /// This client's seen OSC 7501 `done` and `error` records.
    let seen: ProgramStatusSeenStore

    public init(turns: AgentTurnStateStore = .shared, seen: ProgramStatusSeenStore = .shared) {
        self.turns = turns
        self.seen = seen
    }

    /// The reports one tab contributes.
    public func reports(_ tab: TabModel) -> [StatusReport] {
        var reports: [StatusReport] = []
        if let agent = tab.agent, let state = state(agent.state) {
            reports.append(StatusReport(id: "agent:\(tab.id)", source: .agent, state: state,
                                        label: agent.agent, updatedAtMs: agent.updatedAtMs))
        }
        if let record = ProgramStatusRecord.strongest(seen.visible(tab)), let state = state(record) {
            // The title only: `app` is a machine name, never the only label.
            reports.append(StatusReport(id: "program:\(tab.id)", source: .program, state: state, label: record.title))
        }
        if let ref = tab.agentSession, let turn = turns.state(for: ref) {
            reports.append(StatusReport(id: "acp:\(ref.session ?? tab.id)", source: .agent, state: state(turn), label: ref.harness))
        }
        return reports
    }

    /// The acpmux turn state of an agent chat tab, nil for every other tab.
    public func turn(_ tab: TabModel) -> AgentTurnState? {
        tab.agentSession.flatMap(turns.state(for:))
    }

    /// An acpmux turn or an OSC 7501 program waits for the user (the tab's
    /// still attention badge).
    public func needsInput(_ tab: TabModel) -> Bool {
        turn(tab) == .needsInput || ProgramStatusRecord.strongest(tab.programStatus)?.state == .blocked
    }

    /// An unseen OSC 7501 outcome for the tab's badge: `error` is a failure,
    /// `done` a success, until the user looks at the terminal. Nil while a
    /// stronger record (blocked, working) is live or nothing is unseen.
    public func outcome(_ tab: TabModel) -> TabStatus? {
        switch ProgramStatusRecord.strongest(seen.visible(tab))?.state {
        case .error?: .failure
        case .done?: .success
        default: nil
        }
    }

    /// One tab's merged status.
    public func summary(_ tab: TabModel) -> StatusSummary {
        StatusStack.resolve(reports(tab), honoring: honored)
    }

    /// The strongest loading or working report of one tab, for the tab's
    /// icon slot: a waiting or failed source does not hide another source's
    /// mark there, because the tab's badge already marks those states.
    /// Agent work leaves the slot when `showAgentWorkingOnTabs` is off.
    public func loading(_ tab: TabModel) -> StatusSummary {
        let showsWorking = DesignSettings.shared.statusIndicator.showsAgentWorkingOnTabs
        return StatusStack.resolve(reports(tab).filter { $0.state.isLoading || ($0.state.isWorking && showsWorking) },
                                   honoring: honored)
    }

    /// Some tab of a workspace has agent work (an acpmux turn, a hook or an
    /// OSC 7501 `working` record), even while a stronger state (waiting)
    /// wins the row's merged status: the row's working slot
    /// (`WorkspaceRowContent.showsWorking`).
    public func isWorking(tabs: [TabModel]) -> Bool {
        tabs.contains { tab in reports(tab).contains { $0.state.isWorking } }
    }

    /// A workspace's merged status over its tabs.
    public func summary(tabs: [TabModel]) -> StatusSummary {
        StatusStack.resolve(tabs.flatMap(reports), honoring: honored)
    }

    /// Sources whose style hint wins (`appearance.statusIndicator.honorStatusStyle`).
    var honored: Set<StatusReport.Source> { DesignSettings.shared.statusIndicator.honoredStyleSources }

    /// Agent hook state as an indicator state. `done` is not shown here:
    /// the tab's status badge marks it, and a finished agent is not loading.
    func state(_ agent: AgentState) -> StatusIndicatorState? {
        switch agent {
        case .working: .working
        case .blocked: .waiting
        case .idle, .done, .unknown: nil
        }
    }

    /// An OSC 7501 record as an indicator state. `reports` passes only
    /// records still to show, so a `done` or `error` here is unseen.
    func state(_ record: ProgramStatusRecord) -> StatusIndicatorState? {
        switch record.state {
        case .working: .working(progress: record.progress.map { Double($0) / 100 })
        case .blocked: .waiting
        case .error: .error
        case .done: .success
        case .idle: nil
        }
    }

    /// An acpmux turn state as an indicator state.
    func state(_ turn: AgentTurnState) -> StatusIndicatorState {
        switch turn {
        case .working: .working
        case .needsInput: .waiting
        case .failed: .error
        }
    }
}
