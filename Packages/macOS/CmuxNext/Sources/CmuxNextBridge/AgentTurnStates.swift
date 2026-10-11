public import CmuxNextDaemon
public import Foundation
public import Observation

/// What an acpmux session is doing for the working and needs-input
/// indicators (WORKING-AND-LOADING-INDICATORS). acpmux owns the fact (the
/// summary's `indicator`, cx-zlox); the app only mirrors it.
public nonisolated enum AgentTurnState: Hashable, Sendable {
    /// A prompt turn runs (`indicator` = `working`).
    case working
    /// The turn waits for the user: a permission or a question
    /// (`indicator` = `input`).
    case needsInput
    /// The last turn failed (`indicator` = `failed`).
    case failed
    /// The agent went away before it answered (`indicator` = `lost`). A
    /// disconnect after an answer stays done: the next prompt respawns it.
    case lost
    /// The last turn (`turn`, its acpmux turn id) completed: done until the
    /// user looks at the chat (client seen state, `ProgramStatusSeenStore`),
    /// like an OSC 7501 done. acpmux `unread` is not enough: an open chat tab
    /// stays attached in a background workspace.
    case done(turn: String)

    /// The state of one `_acpmux/watch` / `session_changed` session summary,
    /// read from its `indicator`; nil when acpmux shows no dot.
    public static func of(summary: [String: Any]) -> AgentTurnState? {
        switch summary["indicator"] as? String {
        case "input"?: return .needsInput
        case "working"?: return .working
        case "failed"?: return .failed
        case "lost"?: return .lost
        case "done"?:
            let lastTurn = summary["lastTurn"] as? [String: Any]
            return .done(turn: lastTurn?["turnId"] as? String ?? (lastTurn?["endedAt"] as? NSNumber)?.stringValue ?? "")
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
        if let change = Self.change(params) { states[change.session] = change.state }
    }

    /// One decoded `_acpmux/session_changed` (decode it off the main actor): the session and
    /// its new state (nil: no indicator, or purged). Nil when the line names no session state.
    public static func change(_ params: [String: Any]) -> (session: String, state: AgentTurnState?)? {
        guard let id = params["sessionId"] as? String else { return nil }
        if params["kind"] as? String == "purged" { return (id, nil) }
        guard let summary = params["session"] as? [String: Any] else { return nil }
        return (summary["sessionId"] as? String ?? id, AgentTurnState.of(summary: summary))
    }

    /// Sets one session's state. False when it already had that state: the caller then
    /// leaves the observed store untouched, so no tab or row redraws for it.
    @discardableResult
    public mutating func set(_ session: String, _ state: AgentTurnState?) -> Bool {
        guard states[session] != state else { return false }
        states[session] = state
        return true
    }

    /// The completed turns of a watch result that a client watched as they
    /// ended (acpmux `unread` false): the app starts them seen, so a
    /// (re)connect does not light up every old chat; a turn that ended
    /// unwatched stays done until the chat is opened.
    public static func settledTurns(_ result: [String: Any]) -> [(session: String, turn: String)] {
        (result["sessions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap { summary in
            guard let session = summary["sessionId"] as? String, (summary["unread"] as? Bool) != true,
                  case .done(let turn)? = AgentTurnState.of(summary: summary) else { return nil }
            return (session, turn)
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
