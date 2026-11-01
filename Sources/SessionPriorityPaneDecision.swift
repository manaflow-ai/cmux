import CMUXAgentLaunch
import Foundation

/// Whether one Claude pane should be restarted for its workspace's target, or left alone and why.
enum SessionPriorityPaneDecision {
    enum Leave: Equatable {
        case manual(SessionPriorityManualSignal)
        case noTarget
        case nothingToApply
        case upToDate
        case awaitingRestart
    }

    enum Action: Equatable {
        case restart(SessionPriorityTarget)
        case leave(Leave)
    }

    /// Checks, in order: a manual signal (fresh, else sticky), no target, an empty target, a
    /// target the pane already runs with, a restart still waiting for its new session.
    static func decide(
        target: SessionPriorityTarget?,
        manualSignal: SessionPriorityManualSignal?,
        stickyManual: SessionPriorityManualSignal?,
        currentEffort: ClaudeEffortLevel?,
        currentModel: String?,
        awaitingSessionStart: Bool
    ) -> Action {
        if let signal = manualSignal ?? stickyManual { return .leave(.manual(signal)) }
        guard let target else { return .leave(.noTarget) }
        if target.isEmpty { return .leave(.nothingToApply) }
        let effortMatches = target.effort.map { $0 == currentEffort } ?? true
        let modelMatches = target.model.map { $0 == currentModel } ?? true
        if effortMatches && modelMatches { return .leave(.upToDate) }
        if awaitingSessionStart { return .leave(.awaitingRestart) }
        return .restart(target)
    }
}
