import CmuxAgentReplica
import Foundation

/// Centralizes gui.v1 idle gating.
///
/// Process observation runs while a phone subscribes to `gui.v1.sessions` or
/// any session remains live/recent. Per-journal file watchers run while a phone
/// subscribes to that session's journal topic or the session is live/recent.
@MainActor
struct AgentGUISubscriptionPolicy {
    static func isLiveOrRecentlyActive(_ session: AgentSessionSnapshot, nowMS: Int) -> Bool {
        switch session.phase {
        case .working, .needsInput:
            return true
        case .idle, .starting, .unknown:
            return nowMS - session.lastActivityHint < AgentGUIConstants.liveRecentActivityWindowMS
        case .ended:
            return false
        }
    }

    static func shouldRunObservation(hasSessionSubscribers: Bool, hasLiveRecentSession: Bool) -> Bool {
        hasSessionSubscribers || hasLiveRecentSession
    }

    static func shouldRunJournal(hasJournalSubscribers: Bool, session: AgentSessionSnapshot?, nowMS: Int) -> Bool {
        hasJournalSubscribers || session.map { isLiveOrRecentlyActive($0, nowMS: nowMS) } == true
    }
}
