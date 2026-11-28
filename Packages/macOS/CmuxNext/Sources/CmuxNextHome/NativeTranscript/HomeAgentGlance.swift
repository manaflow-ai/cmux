public import CmuxNextIcons
public import CmuxNextDesign

/// One of the user's agents as the empty Chief conversation lists it
/// (`HomeFirstRunView`): its tab, the name its tab shows, and one word for
/// what it is doing. The host maps these from the same tab status the tab
/// strip and the sidebar draw, so Home never says something they do not.
public nonisolated struct HomeAgentGlance: Sendable, Equatable {
    /// What the agent is doing, most urgent first (the list's order).
    public nonisolated enum Status: Int, Sendable, Comparable {
        /// Waits for the user: a question, a permission, input.
        case needsYou
        /// Its turn or program failed and the user has not looked yet.
        case failed
        /// Finished a turn the user has not looked at yet.
        case done
        /// Nothing to report.
        case idle
        /// Working on a turn.
        case working

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The daemon tab id the host opens on click.
    public var id: String
    public var title: String
    public var icon: IconName
    public var status: Status
    /// The tab's state in the shared indicator, as the strip and the sidebar draw it (blocked
    /// kind, progress); defaults to the status's own.
    public var indicator: StatusIndicatorState
    /// The winning report's style hint; nil uses `appearance.statusIndicator.style`.
    public var indicatorStyle: StatusIndicatorStyle?

    public init(id: String, title: String, icon: IconName, status: Status,
                indicator: StatusIndicatorState? = nil, indicatorStyle: StatusIndicatorStyle? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.status = status
        self.indicator = indicator ?? status.indicator
        self.indicatorStyle = indicatorStyle
    }

    /// At most `limit` agents, most urgent first; agents with the same
    /// status keep their given order (the sidebar's).
    public static func shortlist(_ agents: [HomeAgentGlance], limit: Int = 5) -> [HomeAgentGlance] {
        Array(agents.enumerated().sorted { ($0.element.status, $0.offset) < ($1.element.status, $1.offset) }
            .prefix(limit).map(\.element))
    }
}

extension HomeAgentGlance.Status {
    /// The status in the shared indicator when the host gives none.
    nonisolated var indicator: StatusIndicatorState {
        switch self {
        case .needsYou: .waiting(kind: nil)
        case .failed: .error
        case .done: .success
        case .idle: .idle
        case .working: .working(progress: nil)
        }
    }
}
