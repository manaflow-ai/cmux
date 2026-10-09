public import CmuxNextDaemon
public import Foundation
public import Observation

/// What an acpmux session is doing for the working and needs-input
/// indicators (WORKING-AND-LOADING-INDICATORS). acpmux owns the fact
/// (`SessionStatus` plus pending permissions); the app only mirrors it.
public nonisolated enum AgentTurnState: Hashable, Sendable {
    /// A prompt turn runs (`running`, no permission pending).
    case working
    /// The turn waits for the user: a permission or a question
    /// (`waiting`, or `pendingPermissions` > 0).
    case needsInput
    /// The last turn failed (`lastTurn.status` = `failed`). A disconnect
    /// alone is not a failure: the next prompt respawns the agent.
    case failed
    /// The last turn completed while no client watched the chat (acpmux
    /// `unread`): done until the chat is opened, which clears `unread`.
    case done

    /// The state of one `_acpmux/watch` / `session_changed` session summary;
    /// nil when no turn runs and the last turn did not fail, and always for
    /// a closed session.
    public static func of(summary: [String: Any]) -> AgentTurnState? {
        let status = summary["status"] as? String
        if status == "closed" { return nil }
        if ((summary["pendingPermissions"] as? NSNumber)?.intValue ?? 0) > 0 || status == "waiting" { return .needsInput }
        if status == "running" { return .working }
        let lastTurn = summary["lastTurn"] as? [String: Any]
        switch lastTurn?["status"] as? String {
        case "failed"?: return .failed
        case "completed"?, "ok"? where (summary["unread"] as? Bool) == true: return .done
        default: return nil
        }
    }
}

/// Every local acpmux session's turn state, reduced from one `_acpmux/watch`
/// result and its `_acpmux/session_changed` pushes (no poll). Pure.
public nonisolated struct AgentTurnStates: Hashable, Sendable {
    private var states: [String: AgentTurnState] = [:]

    public init() {}

    /// Replaces every session with the sessions of a watch result.
    public mutating func reset(_ result: [String: Any]) {
        states = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) { upsert(summary) }
    }

    /// Applies one `_acpmux/session_changed`; a `purged` session leaves.
    public mutating func apply(changed params: [String: Any]) {
        guard let id = params["sessionId"] as? String else { return }
        if params["kind"] as? String == "purged" {
            states[id] = nil
        } else if let summary = params["session"] as? [String: Any] {
            upsert(summary)
        }
    }

    /// Nothing is known any more (the watch connection closed).
    public mutating func clear() { states = [:] }

    public subscript(session: String) -> AgentTurnState? { states[session] }

    private mutating func upsert(_ summary: [String: Any]) {
        guard let id = summary["sessionId"] as? String else { return }
        states[id] = AgentTurnState.of(summary: summary)
    }
}

/// The app's mirror of the local acpmux turn states. The app's watch feed
/// writes it; `StatusMapping` reads it while the tab strip and the sidebar
/// observe, so a pushed change redraws exactly the tabs and rows that read it.
@Observable @MainActor
public final class AgentTurnStateStore {
    public static let shared = AgentTurnStateStore()

    /// The states of the sessions on `localHost`.
    public var states = AgentTurnStates()
    /// `install:<id>` of this Mac; a chat tab of another host has no state
    /// here (its acpmux runs elsewhere).
    public var localHost: String?

    public init() {}

    /// The turn state of the session an agent chat tab shows.
    public func state(for ref: AgentSessionRef) -> AgentTurnState? {
        guard let session = ref.session, let localHost, ref.host == localHost else { return nil }
        return states[session]
    }
}
