/// One reported status from one source. Several sources can report about
/// the same tab or workspace at once (an agent hook, `cmux status set`, a
/// `status run`, OSC 9;4 progress, a running command); `StatusStack` picks
/// the one the indicator shows and keeps the rest for the hover detail.
public nonisolated struct StatusReport: Hashable, Sendable, Identifiable {
    /// Where a report comes from, strongest first when states tie.
    public enum Source: String, Hashable, Sendable, CaseIterable {
        /// `cmux status set` / MCP / mux tools: someone asked explicitly.
        case explicit
        /// `cmux status run -- cmd`.
        case run
        /// Agent hooks (Claude, Codex, ...).
        case agent
        /// OSC 9;4 progress the terminal program emitted.
        case terminalProgress
        /// A browser page loading.
        case browser
        /// A shell command running (shell integration, inferred).
        case command

        var rank: Int {
            switch self {
            case .explicit: 6
            case .run: 5
            case .agent: 4
            case .terminalProgress: 3
            case .browser: 2
            case .command: 1
            }
        }
    }

    /// Stable within its source (status key, terminal id, agent session).
    public var id: String
    public var source: Source
    public var state: StatusIndicatorState
    /// Short human text ("Tests", "Claude: editing Foo.swift").
    public var label: String?
    /// The style the reporter asked for; nil uses the user's setting.
    public var style: StatusIndicatorStyle?
    /// Milliseconds since 1970; the newer report wins a full tie.
    public var updatedAtMs: UInt64

    public init(id: String, source: Source, state: StatusIndicatorState, label: String? = nil,
                style: StatusIndicatorStyle? = nil, updatedAtMs: UInt64 = 0) {
        self.id = id
        self.source = source
        self.state = state
        self.label = label
        self.style = style
        self.updatedAtMs = updatedAtMs
    }
}

/// The merged status of one tab or workspace.
public nonisolated struct StatusSummary: Hashable, Sendable {
    /// What the indicator draws.
    public var state: StatusIndicatorState
    /// The winning report's style hint; nil uses the setting.
    public var style: StatusIndicatorStyle?
    /// Every visible report, most important first (hover detail).
    public var reports: [StatusReport]

    public static let idle = StatusSummary(state: .idle, style: nil, reports: [])

    public init(state: StatusIndicatorState, style: StatusIndicatorStyle?, reports: [StatusReport]) {
        self.state = state
        self.style = style
        self.reports = reports
    }

    /// The most important report, if any.
    public var primary: StatusReport? { reports.first }
}

/// Merge rule for several reports about one target
/// (plans/cmux-next/status-indicators.md, "Stacking").
public nonisolated enum StatusStack {
    /// Importance of a state alone: problems first, then work, then done.
    static func stateRank(_ state: StatusIndicatorState) -> Int {
        switch state {
        case .error: 6
        case .waiting: 5
        case .busy: 4
        case .paused: 3
        case .success: 2
        case .idle: 0
        }
    }

    /// True when `a` is shown in preference to `b`: state rank, then a known
    /// progress over an indeterminate one (it says more), then source rank,
    /// then the newer report, then id (deterministic).
    public static func precedes(_ a: StatusReport, _ b: StatusReport) -> Bool {
        let ra = stateRank(a.state), rb = stateRank(b.state)
        if ra != rb { return ra > rb }
        let pa = a.state.progress != nil, pb = b.state.progress != nil
        if pa != pb { return pa }
        if a.source.rank != b.source.rank { return a.source.rank > b.source.rank }
        if a.updatedAtMs != b.updatedAtMs { return a.updatedAtMs > b.updatedAtMs }
        return a.id < b.id
    }

    /// The winning report's style hint counts only when its source is in
    /// `honoring` (`appearance.statusIndicator.honorStatusStyle`).
    public static func resolve(_ reports: [StatusReport],
                               honoring: Set<StatusReport.Source> = Set(StatusReport.Source.allCases)) -> StatusSummary {
        let visible = reports.filter { $0.state.isVisible }.sorted(by: precedes)
        guard let top = visible.first else { return .idle }
        return StatusSummary(state: top.state, style: honoring.contains(top.source) ? top.style : nil, reports: visible)
    }

    /// A parent's summary (a workspace over its tabs, a collapsed group over
    /// its workspaces): every child's reports merged.
    public static func rollUp(_ children: [StatusSummary], own: [StatusReport] = []) -> StatusSummary {
        resolve(children.flatMap(\.reports) + own)
    }
}
