public import CmuxNextDaemon
import Foundation

/// An acpmux chat's moments (u3320), from two of its mirrored summaries (`AgentTurnStateStore`).
extension AgentTimeline {
    /// The moments between a chat's last state and detail and its new ones: a new turn (its
    /// prompt when acpmux names one), a wait for the person, a finished or failed turn.
    public static func chatEvents(from oldState: AgentTurnState?, _ oldDetail: AgentChatDetail?,
                                  to newState: AgentTurnState?, _ newDetail: AgentChatDetail?, nowMs: UInt64) -> [AgentTimelineEvent] {
        let laneSince = newDetail?.laneSinceMs
        switch newState {
        case .working?:
            let started = newDetail?.turnStartedAtMs
            // A new turn: work began, or acpmux names a later turn start than the one held.
            let newTurn = oldState != .working && oldState != .needsInput
                || (started != nil && started != oldDetail?.turnStartedAtMs)
            guard newTurn else { return [] }
            let at = started ?? laneSince ?? nowMs
            // acpmux's inbox notice is no prompt: the turn started working, and the History of
            // what was asked leaves it out (Leo 2026-11-01: "the details aren't even very useful").
            if newDetail?.promptIsNotice == true { return [AgentTimelineEvent(kind: .started, atMs: at, isNotice: true)] }
            if let prompt = newDetail?.prompt { return [AgentTimelineEvent(kind: .prompt, atMs: at, text: prompt)] }
            return [AgentTimelineEvent(kind: .started, atMs: at)]
        case .needsInput?:
            guard oldState != .needsInput else { return [] }
            return [AgentTimelineEvent(kind: .waiting, atMs: laneSince ?? nowMs)]
        case .failed?, .lost?:
            guard oldState != newState else { return [] }
            return [AgentTimelineEvent(kind: .failed, atMs: laneSince ?? nowMs)]
        case .done?, nil:
            guard oldState == .working || oldState == .needsInput else { return [] }
            return [AgentTimelineEvent(kind: .finished, atMs: laneSince ?? nowMs)]
        }
    }
}
