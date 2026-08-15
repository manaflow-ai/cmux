/// Aggregates immutable agent-activity values for sidebar presentation.
public struct SidebarAgentActivityAggregator: Sendable {
    /// Creates an agent-activity aggregator.
    public init() {}

    /// Counts the highest-priority activity state already selected for each panel.
    ///
    /// - Parameter panelActivities: One activity value per panel.
    /// - Returns: The number of running and needs-input panels.
    public func counts<S: Sequence>(panelActivities: S) -> SidebarAgentActivityCounts
    where S.Element == SidebarAgentPanelActivity {
        panelActivities.reduce(into: SidebarAgentActivityCounts()) { counts, activity in
            switch activity {
            case .running:
                counts.running += 1
            case .needsInput:
                counts.needsInput += 1
            case .inactive:
                break
            }
        }
    }

    /// Combines workspace counts into a larger sidebar scope.
    ///
    /// - Parameter counts: Counts from the workspaces in the scope.
    /// - Returns: The combined counts.
    public func total<S: Sequence>(counts: S) -> SidebarAgentActivityCounts
    where S.Element == SidebarAgentActivityCounts {
        counts.reduce(SidebarAgentActivityCounts(), +)
    }
}
