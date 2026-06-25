import Foundation

/// The tracking status of a single agent pane, for diagnostics.
enum PaneTrackingStatus: Equatable, Sendable {
    /// A hook-proven session exists — the pane is tracked and resumable.
    case tracked
    /// A supported agent is running but cmux has no hook session for it — the
    /// session is not being recorded and won't resume (the wrapper was bypassed).
    case untracked
    /// An agent is running whose hooks cmux does not inject; nothing to track.
    case unsupportedAgent(RestorableAgentKind)
}

/// Pure, point-in-time classifier for "which panes are (un)tracked", backing a
/// read-only diagnostic (a `doctor`-style listing). Unlike the live monitor it
/// has no grace window or history — it reports the current state so a user can
/// answer "will my windows resume?" on demand.
struct UntrackedAgentSessionDiagnostics {
    /// One pane's classification.
    struct PaneReport: Equatable, Sendable {
        var key: RestorableAgentSessionIndex.PanelKey
        var agentKind: RestorableAgentKind
        var status: PaneTrackingStatus
    }

    func classify(
        detectedAgents: [RestorableAgentSessionIndex.PanelKey: RestorableAgentKind],
        hasHookSession: (RestorableAgentSessionIndex.PanelKey) -> Bool
    ) -> [PaneReport] {
        detectedAgents
            .map { key, kind -> PaneReport in
                let status: PaneTrackingStatus
                if hasHookSession(key) {
                    status = .tracked
                } else if UntrackedAgentSessionDetector.isSupported(kind) {
                    status = .untracked
                } else {
                    status = .unsupportedAgent(kind)
                }
                return PaneReport(key: key, agentKind: kind, status: status)
            }
            // Stable order for deterministic output: untracked first (the thing a
            // user is looking for), then tracked, then unsupported; tie-break by id.
            .sorted { lhs, rhs in
                func rank(_ s: PaneTrackingStatus) -> Int {
                    switch s {
                    case .untracked: return 0
                    case .tracked: return 1
                    case .unsupportedAgent: return 2
                    }
                }
                if rank(lhs.status) != rank(rhs.status) { return rank(lhs.status) < rank(rhs.status) }
                return lhs.key.panelId.uuidString < rhs.key.panelId.uuidString
            }
    }

    /// Count of panes running a supported agent with no hook session — the
    /// headline number for "you have N windows that won't resume".
    func untrackedCount(_ reports: [PaneReport]) -> Int {
        reports.filter { $0.status == .untracked }.count
    }
}
