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
    /// The last turn completed while no pane showed the chat, and none has
    /// shown it since (acpmux `unread`, cx-n8ou): a pane tells acpmux whether
    /// its page is visible, so a chat tab in a background workspace does not
    /// count as seen.
    case done

    /// The state of one `_acpmux/watch` / `session_changed` session summary,
    /// read from its `indicator`; nil when acpmux shows no dot.
    public static func of(summary: [String: Any]) -> AgentTurnState? {
        switch summary["indicator"] as? String {
        case "input"?: return .needsInput
        case "working"?: return .working
        case "failed"?: return .failed
        case "lost"?: return .lost
        case "done"?: return summary["unread"] as? Bool == true ? .done : nil
        default: return nil
        }
    }
}

/// What the hover card says about an agent chat beyond its state (acpmux's session summary):
/// the model it runs, when its running turn started, and that turn's prompt.
public nonisolated struct AgentChatDetail: Hashable, Sendable {
    public var model: String?
    /// When the running turn started (Unix ms, `turn.startedAt`); nil between turns.
    public var turnStartedAtMs: UInt64?
    /// The running turn's prompt preview (`turn.prompt`).
    public var prompt: String?
    /// What the session does as acpmux decided it (`lane.state`: working, input, idle,
    /// failed, lost) and since when (`lane.since`, Unix ms), for the tab's hover card.
    public var laneState: String?
    public var laneSinceMs: UInt64?
    /// The session's folder (`cwd`).
    public var cwd: String?

    public init(model: String? = nil, turnStartedAtMs: UInt64? = nil, prompt: String? = nil,
                laneState: String? = nil, laneSinceMs: UInt64? = nil, cwd: String? = nil) {
        self.model = model
        self.turnStartedAtMs = turnStartedAtMs
        self.prompt = prompt
        self.laneState = laneState
        self.laneSinceMs = laneSinceMs
        self.cwd = cwd
    }

    /// A summary's detail; nil when it names none of them.
    public static func of(summary: [String: Any]) -> AgentChatDetail? {
        let turn = summary["turn"] as? [String: Any]
        let text = { (value: Any?) -> String? in
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let lane = summary["lane"] as? [String: Any]
        let detail = AgentChatDetail(model: text(summary["model"]), turnStartedAtMs: (turn?["startedAt"] as? NSNumber)?.uint64Value,
                                     prompt: text(turn?["prompt"]), laneState: text(lane?["state"]),
                                     laneSinceMs: (lane?["since"] as? NSNumber)?.uint64Value, cwd: text(summary["cwd"]))
        return detail == AgentChatDetail() ? nil : detail
    }

    /// The detail of every session of a watch result that has one.
    public static func details(_ result: [String: Any]) -> [String: AgentChatDetail] {
        var details: [String: AgentChatDetail] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let detail = of(summary: summary) { details[id] = detail }
        }
        return details
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

    /// One decoded `_acpmux/session_changed` (decode it off the main actor): the session, its
    /// new state (nil: no indicator, or purged), its last message (`lastMessage`, cx-13w3.1) and
    /// whether its notifications are muted. Nil when the line names no session state.
    public static func change(_ params: [String: Any])
        -> (session: String, state: AgentTurnState?, lastMessage: String?, muted: Bool, title: String?)? {
        guard let id = params["sessionId"] as? String else { return nil }
        if params["kind"] as? String == "purged" { return (id, nil, nil, false, nil) }
        guard let summary = params["session"] as? [String: Any] else { return nil }
        return (summary["sessionId"] as? String ?? id, AgentTurnState.of(summary: summary), lastMessage(summary), muted(summary),
                title(summary))
    }

    /// A summary's chat title as the page names it (sessionList.ts `sessionTitle`): the name the
    /// user gave, else the agent's title, else the first prompt. A name acpmux generated from the
    /// harness or its family (`claude-sr`, `claude-sr-2`, `codex-fork`) is no title. Nil when the
    /// chat has none yet.
    public static func title(_ summary: [String: Any]) -> String? {
        let name = (summary["name"] as? String) ?? ""
        let bare = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        func generated(from agent: String?) -> Bool {
            guard let agent, !agent.isEmpty, bare.hasPrefix(agent) else { return false }
            // What follows the agent's name is only `-fork` and `-N` parts.
            return bare.dropFirst(agent.count).split(separator: "-", omittingEmptySubsequences: false).dropFirst().allSatisfy { part in
                part == "fork" || (!part.isEmpty && part.allSatisfy { ("0"..."9").contains($0) })
            } && (bare.count == agent.count || bare.dropFirst(agent.count).hasPrefix("-"))
        }
        if !name.isEmpty, !generated(from: summary["harness"] as? String), !generated(from: summary["family"] as? String) {
            return name
        }
        for key in ["title", "lastPrompt"] {
            if let text = (summary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    /// The title of every session of a watch result that has one.
    public static func titles(_ result: [String: Any]) -> [String: String] {
        var titles: [String: String] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let title = title(summary) { titles[id] = title }
        }
        return titles
    }

    /// The acpmux session tag that mutes a chat's notifications (cx-sg1qz), and its value. The
    /// tag lives with the chat, so every window, device and the phone feed honor it; the
    /// cmux-tui daemon posts nothing for a muted chat.
    public static let muteTag = "notifications"
    public static let mutedValue = "muted"

    /// Whether a summary's chat is muted (its `tags`).
    public static func muted(_ summary: [String: Any]) -> Bool {
        (summary["tags"] as? [String: Any])?[muteTag] as? String == mutedValue
    }

    /// The muted sessions of a watch result.
    public static func muted(result: [String: Any]) -> Set<String> {
        Set((result["sessions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.filter(muted).compactMap { $0["sessionId"] as? String })
    }

    /// A summary's `lastMessage` text: the reply's last line, else the prompt; nil before one.
    public static func lastMessage(_ summary: [String: Any]) -> String? {
        guard let text = (summary["lastMessage"] as? [String: Any])?["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// The last message of every session of a watch result.
    public static func lastMessages(_ result: [String: Any]) -> [String: String] {
        var messages: [String: String] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let text = lastMessage(summary) { messages[id] = text }
        }
        return messages
    }

    /// Sets one session's state. False when it already had that state: the caller then
    /// leaves the observed store untouched, so no tab or row redraws for it.
    @discardableResult
    public mutating func set(_ session: String, _ state: AgentTurnState?) -> Bool {
        guard states[session] != state else { return false }
        states[session] = state
        return true
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
    /// Each session's last message (expanded sidebar rows, cx-13w3.1), apart from
    /// `states` so a new reply redraws only the rows that show it.
    public var lastMessages: [String: String] = [:]
    /// The sessions whose notifications are muted (`AgentTurnStates.muted`).
    public var muted: Set<String> = []
    /// Each session's title (`AgentTurnStates.title`), for a chat tab the user has not named.
    public var titles: [String: String] = [:]
    /// Each session's model and running turn (`AgentChatDetail`), for the hover card.
    public var details: [String: AgentChatDetail] = [:]
    /// `install:<id>` of this Mac; a chat tab of another host has no state
    /// here (its acpmux runs elsewhere).
    public var localHost: String?
    /// The watch is up and `states` is acpmux's: false before its first page and after it
    /// closes, when a chat with no state may still be working.
    public var watching = false

    public init() {}

    /// The turn state of the session an agent chat tab shows.
    public func state(for ref: AgentSessionRef) -> AgentTurnState? {
        guard let session = ref.session, let localHost, ref.host == localHost else { return nil }
        return states[session]
    }

    /// The last message of the session an agent chat tab shows.
    public func lastMessage(for ref: AgentSessionRef) -> String? {
        guard let session = ref.session, let localHost, ref.host == localHost else { return nil }
        return lastMessages[session]
    }

    /// The model and running turn of the chat an agent chat tab shows; nil off this Mac.
    public func detail(for ref: AgentSessionRef) -> AgentChatDetail? {
        guard let session = ref.session, let localHost, ref.host == localHost else { return nil }
        return details[session]
    }

    /// The title of the chat an agent chat tab shows; nil when it has none yet or is not on
    /// this Mac.
    public func title(for ref: AgentSessionRef) -> String? {
        guard let session = ref.session, let localHost, ref.host == localHost else { return nil }
        return titles[session]
    }

    /// Whether the chat an agent chat tab shows has its notifications muted; nil when
    /// the chat is not on this Mac (its acpmux runs elsewhere) or not known yet.
    public func isMuted(_ ref: AgentSessionRef) -> Bool? {
        guard let session = ref.session, let localHost, ref.host == localHost else { return nil }
        return muted.contains(session)
    }
}
