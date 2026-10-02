public import CmuxNextDaemon
public import CmuxNextDesign

/// Turns the status facts the daemon publishes about a tab into
/// `StatusReport`s, and merges them per tab and per workspace with
/// `StatusStack` (plans/cmux-next/status-indicators.md). The app only
/// renders: every fact here is written by its owner (agent hooks through
/// the session host today; `workspace_status` entries, OSC 9;4 terminal
/// progress and running commands once the daemon publishes them).
public struct StatusMapping {
    public static let shared = Self()

    /// The reports one tab contributes.
    public func reports(_ tab: TabModel) -> [StatusReport] {
        var reports: [StatusReport] = []
        if let agent = tab.agent, let state = state(agent.state) {
            reports.append(StatusReport(id: "agent:\(tab.id)", source: .agent, state: state,
                                        label: agent.agent, updatedAtMs: agent.updatedAtMs))
        }
        return reports
    }

    /// One tab's merged status.
    public func summary(_ tab: TabModel) -> StatusSummary {
        StatusStack.resolve(reports(tab), honoring: honored)
    }

    /// The strongest loading report of one tab, for the tab's icon slot:
    /// a waiting or failed source does not hide another source's spinner
    /// there, because the tab's badge already marks those states.
    public func loading(_ tab: TabModel) -> StatusSummary {
        StatusStack.resolve(reports(tab).filter { $0.state.isLoading }, honoring: honored)
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
        case .working: .busy
        case .blocked: .waiting
        case .idle, .done, .unknown: nil
        }
    }
}
