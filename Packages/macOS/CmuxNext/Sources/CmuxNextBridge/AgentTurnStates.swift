public import CmuxNextDaemon
public import Foundation
public import Observation
import os

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

    /// Whether a chat works, as acpmux says (Leo, 2026-11-14: "if it's working then you can try to optimize
    /// but thats it"): its turn runs or waits on the person (a permission or a question), or a subagent or
    /// background command it started still runs. Only a chat that does none of these is idle, and only an
    /// idle chat that is not drawn gives back its page (HiddenChatPages).
    public static func isWorking(_ state: AgentTurnState?, detail: AgentChatDetail?) -> Bool {
        if state == .working || state == .needsInput { return true }
        guard let detail else { return false }
        return detail.subagentsRunning > 0 || detail.commandsRunning > 0
    }

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
    /// What each model call carries now and the window it fits in, in tokens, and what the
    /// session spent in the last 24 hours, in US dollars (acpmux `usageStats`: `contextTokens`,
    /// `contextWindow`, `costUsd24h`); nil when acpmux has not read them.
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var costUsd24h: Double?
    /// The running turn's prompt is acpmux's notice of other agents' messages ("[inbox] New
    /// messages from other agents…", `turn.notice`), not anyone's words: the hover card's
    /// History leaves it out.
    public var promptIsNotice = false
    /// What the chat runs below its turn now, as acpmux counts it (`subagentsRunning`,
    /// `subagentNames`, `commandsRunning`): its running subagents at any depth, the first of
    /// their names, and its running background commands. 0 and empty from an older acpmux.
    public var subagentsRunning = 0
    public var subagentNames: [String] = []
    public var commandsRunning = 0
    /// The chat's latest subagents, oldest first (at most 8, acpmux `recentSubagents`), and how many it started in
    /// all (`subagentsSeen`): the sidebar lists them under the chat's row. Empty and 0 from an older acpmux.
    public var subagents: [Subagent] = []
    public var subagentsSeen = 0
    /// The chat carries acpmux's `archived` tag (one not past its `expires_at`): a hidden page of it
    /// gives back its memory at once (HiddenChatPages).
    public var archived = false
    /// When the chat was archived (Unix ms), from the `archived` tag's value (`_acpmux/archive` writes
    /// the time); nil when it is not archived or the tag holds no time (`"1"`, `"true"`).
    public var archivedAtMs: UInt64?

    public init(model: String? = nil, turnStartedAtMs: UInt64? = nil, prompt: String? = nil,
                laneState: String? = nil, laneSinceMs: UInt64? = nil, cwd: String? = nil,
                contextTokens: Int? = nil, contextWindow: Int? = nil, costUsd24h: Double? = nil, promptIsNotice: Bool = false,
                subagentsRunning: Int = 0, subagentNames: [String] = [], commandsRunning: Int = 0, archived: Bool = false) {
        self.model = model
        self.turnStartedAtMs = turnStartedAtMs
        self.prompt = prompt
        self.laneState = laneState
        self.laneSinceMs = laneSinceMs
        self.cwd = cwd
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.costUsd24h = costUsd24h
        self.promptIsNotice = promptIsNotice
        self.subagentsRunning = subagentsRunning
        self.subagentNames = subagentNames
        self.commandsRunning = commandsRunning
        self.archived = archived
    }

    /// One of the chat's latest subagents (acpmux `recentSubagents[]`).
    public struct Subagent: Hashable, Sendable {
        public var id: String
        /// The subagent that started it; nil for one the chat started.
        public var parent: String?
        /// Its name, else its task, as acpmux masked and cut it.
        public var title: String?
        /// `running`, `done`, `failed` or `stopped`.
        public var state: String

        public init(id: String, parent: String? = nil, title: String? = nil, state: String) {
            (self.id, self.parent, self.title, self.state) = (id, parent, title, state)
        }
    }

    /// A summary's `recentSubagents`: each entry with an id and a state; others are skipped.
    static func subagents(_ value: Any?) -> [Subagent] {
        (value as? [Any] ?? []).compactMap { item in
            guard let item = item as? [String: Any], let id = item["id"] as? String, !id.isEmpty,
                  let state = item["state"] as? String, !state.isEmpty else { return nil }
            let text = { (key: String) in (item[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            return Subagent(id: id, parent: text("parent"), title: text("title"), state: state)
        }
    }

    /// Whether a summary's `tags` hold an `archived` tag in force: a value (`"1"`, `"true"`), or a tag
    /// object whose `expires_at` (Unix ms) has not passed.
    public static func archived(_ summary: [String: Any], nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        switch (summary["tags"] as? [String: Any])?["archived"] {
        case let value as String: return !value.isEmpty && value != "false"
        case let value as NSNumber: return value.boolValue
        case let tag as [String: Any]:
            guard tag["value"] != nil else { return false }
            guard let expires = (tag["expires_at"] as? NSNumber)?.doubleValue else { return true }
            return expires > nowMs
        default: return false
        }
    }

    /// The time a summary's `archived` tag holds (Unix ms) while the tag is in force and its value is a
    /// time (`_acpmux/archive` writes `now_ms`); nil otherwise.
    public static func archivedAtMs(_ summary: [String: Any], nowMs: Double = Date().timeIntervalSince1970 * 1000) -> UInt64? {
        guard archived(summary, nowMs: nowMs) else { return nil }
        let raw = (summary["tags"] as? [String: Any])?["archived"]
        let value = (raw as? [String: Any])?["value"] ?? raw
        if let text = value as? String, let ms = UInt64(text), ms > 1 { return ms }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue > 1 {
            return number.uint64Value
        }
        return nil
    }

    /// A summary's detail; nil when it names none of them.
    public static func of(summary: [String: Any]) -> AgentChatDetail? {
        let turn = summary["turn"] as? [String: Any]
        let text = { (value: Any?) -> String? in
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let lane = summary["lane"] as? [String: Any]
        let usage = summary["usageStats"] as? [String: Any]
        // A count acpmux could not read is null; a negative or non-finite one is no count.
        let amount = { (value: Any?) -> Double? in
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let amount = number.doubleValue
            return amount.isFinite && amount >= 0 ? amount : nil
        }
        let tokens = { (value: Any?) -> Int? in amount(value).flatMap { $0 < Double(Int.max) ? Int($0) : nil } }
        let count = { (value: Any?) -> Int in max(0, (value as? NSNumber)?.intValue ?? 0) }
        var detail = AgentChatDetail(model: text(summary["model"]), turnStartedAtMs: (turn?["startedAt"] as? NSNumber)?.uint64Value,
                                     prompt: text(turn?["prompt"]), laneState: text(lane?["state"]),
                                     laneSinceMs: (lane?["since"] as? NSNumber)?.uint64Value, cwd: text(summary["cwd"]),
                                     contextTokens: tokens(usage?["contextTokens"]),
                                     contextWindow: tokens(usage?["contextWindow"]).flatMap { $0 > 0 ? $0 : nil },
                                     costUsd24h: amount(usage?["costUsd24h"]),
                                     promptIsNotice: turn?["notice"] as? Bool == true,
                                     subagentsRunning: count(summary["subagentsRunning"]),
                                     subagentNames: (summary["subagentNames"] as? [Any] ?? []).compactMap(text),
                                     commandsRunning: count(summary["commandsRunning"]),
                                     archived: archived(summary))
        if detail.archived { detail.archivedAtMs = archivedAtMs(summary) }
        detail.subagents = subagents(summary["recentSubagents"])
        detail.subagentsSeen = count(summary["subagentsSeen"])
        return detail == AgentChatDetail() ? nil : detail
    }

    /// Whether acpmux read any of the chat's usage (`usageStats`).
    public var hasUsage: Bool { contextTokens != nil || contextWindow != nil || costUsd24h != nil }

    /// This detail with `usage`'s usage numbers in place of its own; the rest stays.
    public func withUsage(of usage: AgentChatDetail) -> AgentChatDetail {
        var detail = self
        detail.contextTokens = usage.contextTokens
        detail.contextWindow = usage.contextWindow
        detail.costUsd24h = usage.costUsd24h
        return detail
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

/// One acpmux peer's row of a session on this Mac's acpmux (`peer`): the peer, whether the row
/// went stale (the peer dropped: its state is the last one seen) and the state that row says.
/// Session ids are each daemon's own, so two peers' rows can share one: each keeps its own state.
public nonisolated struct AgentPeerRow: Hashable, Sendable {
    public var name: String
    public var stale: Bool
    public var state: AgentTurnState?

    public init(name: String, stale: Bool, state: AgentTurnState? = nil) {
        self.name = name
        self.stale = stale
        self.state = state
    }

    /// The peer row of a session summary; nil for this Mac's own session. `peer` names the peer
    /// of a push whose summary does not repeat it.
    public static func of(summary: [String: Any], peer: String? = nil) -> AgentPeerRow? {
        (summary["peer"] as? String ?? peer).map {
            AgentPeerRow(name: $0, stale: summary["stale"] as? Bool == true, state: AgentTurnState.of(summary: summary))
        }
    }

    /// Every peer row of a watch result, by session id, then by peer.
    public static func rows(_ result: [String: Any]) -> [String: [String: AgentPeerRow]] {
        var rows: [String: [String: AgentPeerRow]] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let row = of(summary: summary) { rows[id, default: [:]][row.name] = row }
        }
        return rows
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
        -> (session: String, state: AgentTurnState?, lastMessage: String?, muted: Bool, title: String?, generatedTitle: String?, sessionName: String?,
            identity: AgentSessionIdentity?)? {
        guard let id = params["sessionId"] as? String else { return nil }
        if params["kind"] as? String == "purged" { return (id, nil, nil, false, nil, nil, nil, nil) }
        guard let summary = params["session"] as? [String: Any] else { return nil }
        let session = summary["sessionId"] as? String ?? id
        return (session, AgentTurnState.of(summary: summary), lastMessage(summary), muted(summary),
                title(summary), title(summary, includingPrompt: false), sessionName(summary), AgentSessionIdentity.of(summary: summary))
    }

    /// A summary's chat title as the page names it (sessionList.ts `sessionTitle`): the name the
    /// user gave, else the agent's title, else the first prompt. A name acpmux generated from the
    /// harness or its family (`claude-sr`, `claude-sr-2`, `codex-fork`) is no title, nor a Chief's
    /// session name (`optchat-sub-2e448bc2-a345`). A title or prompt reads as its gist
    /// (``promptGist(_:)``): a Chief subagent's `<chat>` view never names its tab. The latest
    /// prompt only stands in while acpmux reports no title at all. Nil when the chat has none yet.
    /// A name that reads as an id or a counter (`cloud-item-14`, ``isOpaqueName(_:)``) yields to
    /// the title or prompt, and stands in only while the chat has neither. The name a person or the agent
    /// gave the session (acpmux `displayName`, ``AgentSessionIdentity``) comes before all of them; the real
    /// title (`includingPrompt` false) stays the chat's own.
    public static func title(_ summary: [String: Any], includingPrompt: Bool = true) -> String? {
        if includingPrompt, let given = AgentSessionIdentity.displayName(summary) { return given }
        guard includingPrompt, let name = sessionName(summary) else { return chatTitle(summary, includingPrompt: includingPrompt) }
        return isOpaqueName(name) ? chatTitle(summary, includingPrompt: true) ?? name : name
    }

    /// Whether a session name reads as an id or a counter rather than its task (acpmux
    /// `session_name::opaque_reason`, sessionList.ts `isOpaqueName`): its last `/` segment ends in
    /// a counter (`cloud-item-14`) or has a hex run of 6 or more with a digit
    /// (`dispatch-019a3f2e`). Leo 2026-11-02: "that's the agents naming them like that".
    public static func isOpaqueName(_ name: String) -> Bool {
        let bare = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        let parts = bare.split(whereSeparator: { "-_.".contains($0) })
        let digits = { (part: Substring) in part.allSatisfy { ("0"..."9").contains($0) } }
        if parts.count > 1, let last = parts.last, digits(last) { return true }
        return parts.contains { part in
            part.count >= 6 && part.allSatisfy(\.isHexDigit) && part.contains { ("0"..."9").contains($0) }
        }
    }

    /// Whether someone renamed the chat (acpmux `rename`): it has former names, and its title is the one
    /// the new name gave it (`titleSource` `named`, hub/turns.rs `rename_as`). That title is real: the
    /// sidebar row and the workspace it names follow the rename (Leo, 2026-11-22: "I DON'T KNOW WHO'S BEEN
    /// RENAMED TO WHAT THE PROPAGATION OF RENAMES ARE INCOMPLETE").
    static func isRenamed(_ summary: [String: Any]) -> Bool {
        summary["titleSource"] as? String == "named" && !((summary["formerNames"] as? [Any])?.isEmpty ?? true)
    }

    /// The agent's title, else (with `includingPrompt`) the latest prompt, as ``title(_:includingPrompt:)`` reads them.
    private static func chatTitle(_ summary: [String: Any], includingPrompt: Bool) -> String? {
        if !includingPrompt {
            // acpmux publishes the first prompt as `title` before its title
            // request completes. Only a source that names a real chat title
            // may feed durable workspace auto-naming; an absent source is an
            // older daemon and is intentionally treated as unknown.
            let source = summary["titleSource"] as? String
            guard let source, ["harness", "generated", "adopted"].contains(source) || isRenamed(summary) else { return nil }
        }
        if let title = summary["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return promptGist(title)
        }
        return includingPrompt ? (summary["lastPrompt"] as? String).flatMap(promptGist) : nil
    }

    /// The prefix of every session name a Chief's presets make (optchat-chief `optchat-sub-…`,
    /// `optchat-chief-…`, `optchat-compact-…`): machine names, never a chat's title.
    static let chiefSessionPrefix = "optchat-"

    /// The launcher/session name, when it is a user-readable name rather than a harness-generated id.
    public static func sessionName(_ summary: [String: Any]) -> String? {
        let name = (summary["name"] as? String) ?? ""
        let bare = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        func generated(from agent: String?) -> Bool {
            guard let agent, !agent.isEmpty, bare.hasPrefix(agent) else { return false }
            // What follows the agent's name is only `-fork` and `-N` parts.
            return bare.dropFirst(agent.count).split(separator: "-", omittingEmptySubsequences: false).dropFirst().allSatisfy { part in
                part == "fork" || (!part.isEmpty && part.allSatisfy { ("0"..."9").contains($0) })
            } && (bare.count == agent.count || bare.dropFirst(agent.count).hasPrefix("-"))
        }
        guard !name.isEmpty, !bare.hasPrefix(chiefSessionPrefix),
              !generated(from: summary["harness"] as? String), !generated(from: summary["family"] as? String) else { return nil }
        return name
    }

    public static func sessionNames(_ result: [String: Any]) -> [String: String] {
        var names: [String: String] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let name = sessionName(summary) { names[id] = name }
        }
        return names
    }

    /// The title of every session of a watch result that has one.
    public static func titles(_ result: [String: Any], includingPrompt: Bool = true) -> [String: String] {
        var titles: [String: String] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let title = title(summary, includingPrompt: includingPrompt) { titles[id] = title }
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

    /// A summary's reply preview. A user message is the raw prompt, not sidebar status.
    public static func lastMessage(_ summary: [String: Any]) -> String? {
        guard let message = summary["lastMessage"] as? [String: Any], message["role"] as? String != "user",
              let text = message["text"] as? String, !text.isEmpty else { return nil }
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

    /// Lays a later page of the same watch result over this one.
    public mutating func merge(_ later: AgentTurnStates) { states.merge(later.states) { $1 } }

    public subscript(session: String) -> AgentTurnState? { states[session] }

    /// Every session's state.
    public var bySession: [String: AgentTurnState] { states }

    /// A peer's row (`peer`) is that peer's session, never this Mac's: its state is the row's
    /// (``AgentPeerRow/rows(_:)``), so a peer working never reads as a session of this Mac working.
    private mutating func upsert(_ summary: [String: Any]) {
        guard let id = summary["sessionId"] as? String, summary["peer"] == nil else { return }
        states[id] = AgentTurnState.of(summary: summary)
    }
}

/// The app's mirror of the local acpmux turn states. The app's watch feed
/// writes it; `StatusMapping` reads it while the tab strip and the sidebar
/// observe. Keyed observable storage (perf-speed-of-light.md I2): each
/// session is its own observable record, so a pushed change of one chat
/// redraws only the tabs and rows that read that chat, never every agent tab.
@Observable @MainActor
public final class AgentTurnStateStore {
    public static let shared = AgentTurnStateStore()

    /// One session's mirrored facts.
    @Observable @MainActor
    final class Session {
        var state: AgentTurnState?
        /// Each acpmux peer's row of this session id (chats of other machines), by peer.
        var peers: [String: AgentPeerRow] = [:]
        /// The last message (expanded sidebar rows, cx-13w3.1).
        var lastMessage: String?
        var muted = false
        /// The chat's title (`AgentTurnStates.title`), for a chat tab the user has not named.
        var title: String?
        /// The chat's real title, excluding its session name and first prompt.
        var generatedTitle: String?
        /// The launcher/session name, when it is user-readable rather than harness-generated.
        var sessionName: String?
        /// Who the session is (acpmux `displayName`, `formerNames`, `icon`).
        var identity: AgentSessionIdentity?
        /// ``identity``'s icon drawn once (``AgentTurnStateStore/iconArt(for:)``); cleared when the identity changes.
        @ObservationIgnored var iconArt: HarnessIconLookup.Art??
        /// The model and running turn (`AgentChatDetail`), for the hover card.
        var detail: AgentChatDetail?
        /// The session whose agent started this one (acpmux `startedBy`); nil for a root. Not
        /// observed: only a chat page's open request reads it.
        @ObservationIgnored var startedBy: String?
        /// The chat's recent prompts, waits and finished turns (u3320), read when a hover card
        /// opens; not observed (a new moment redraws nothing).
        @ObservationIgnored var timeline = AgentTimeline()
        /// The watch that wrote this record last (``AgentTurnStateStore/localSource``, or a
        /// mirrored acpmux's host): a page of one watch replaces only its own sessions.
        @ObservationIgnored var source = AgentTurnStateStore.localSource
        /// The store's write count when the watch last wrote this record: past
        /// ``AgentTurnStateStore/recordCap`` the idle records written longest ago go first.
        @ObservationIgnored var lastWrite: UInt64 = 0
    }

    /// The source of the app's own acpmux watch.
    public nonisolated static let localSource = "local"

    /// One chat that carries acpmux's `archived` tag: what the sidebar's Archived fold lists.
    public nonisolated struct ArchivedChat: Hashable, Sendable {
        public var id: String
        public var title: String
        public var cwd: String?
        /// When it was archived (Unix ms); nil when the tag holds no time.
        public var archivedAtMs: UInt64?
        /// The watch that reported it (``AgentTurnStateStore/localSource`` or a mirrored acpmux's host).
        public var source: String

        public init(id: String, title: String, cwd: String? = nil, archivedAtMs: UInt64? = nil, source: String = AgentTurnStateStore.localSource) {
            self.id = id
            self.title = title
            self.cwd = cwd
            self.archivedAtMs = archivedAtMs
            self.source = source
        }
    }

    /// The archived chats by session id, kept as each session's facts arrive (one write per archive,
    /// unarchive or rename of an archived chat, never a walk over every session). Its own observable, so a
    /// reader of the archived chats redraws only when they change.
    @Observable @MainActor
    public final class ArchivedChats {
        public private(set) var byID: [String: ArchivedChat] = [:]

        public init() {}

        public var count: Int { byID.count }

        public func contains(_ id: String) -> Bool { byID[id] != nil }

        /// Sets or removes one chat; writes only a change.
        public func set(_ id: String, _ chat: ArchivedChat?) {
            guard byID[id] != chat else { return }
            byID[id] = chat
        }

        /// The archived chats, newest archive first (an unknown time last, then by title): `limit` of them.
        public func newest(limit: Int) -> [ArchivedChat] {
            Array(byID.values.sorted { a, b in
                if a.archivedAtMs != b.archivedAtMs { return (a.archivedAtMs ?? 0) > (b.archivedAtMs ?? 0) }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }.prefix(max(0, limit)))
        }
    }

    /// The chats acpmux reports archived, this Mac's and the mirrored acpmux's.
    public let archivedChats = ArchivedChats()

    /// The records by session id; not observed itself (a reader observes the record it reads).
    /// Only the watch feed's writes make a record; reads never do. A record leaves when acpmux
    /// deletes its chat or its watch's whole list no longer has it (``sessionEnded(_:)``), and
    /// past ``recordCap`` the idle records written longest ago go.
    @ObservationIgnored var sessions: [String: Session] = [:]
    /// One signal per session read while it had no record (``existing(_:)``): the record's first write fires that
    /// session's signal only, so its reader reads again then. A store-wide "a record was made" count here woke every
    /// reader of every record-less chat (each sidebar row of an old chat, in each window) whenever any session got its
    /// first record: a subagent starting, another machine's chat, a watch page (Leo's NIGHTLY 2026-11-21: 167 of 193
    /// chat tabs had no record, and those rows mapped again from the display frame on each new session anywhere).
    @ObservationIgnored var awaited: [String: AgentTurnRecordSignal] = [:]
    /// The most records the store keeps: far above any real list (Leo's daemon lists 10,790
    /// sessions); a bound for a watch that keeps listing new ids.
    @ObservationIgnored public var recordCap = 40_000
    /// The store's write count (``Session/lastWrite``).
    @ObservationIgnored var writes: UInt64 = 0
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-turn-states")
    /// Bumped by every turn state change of any session: for a reader that
    /// follows all of them (one read, no walk).
    public internal(set) var stateRevision: UInt64 = 0
    /// How many of this Mac's sessions (its own acpmux's and the mirrored ones') run a turn now, kept by
    /// ``setState(_:session:)`` (and a dropped record's ``forget``): ``hasWorkingSession`` is one read of it, never
    /// a walk of every record, and a reader of it hears only a change of the count. A peer's row never counts
    /// (``AgentPeerRow``).
    public internal(set) var workingSessions = 0
    /// `install:<id>` of this Mac; a chat tab of another host has no state
    /// here (its acpmux runs elsewhere).
    public var localHost: String?
    /// The hosts of other acpmux daemons on this Mac whose watch also feeds this store (the
    /// Chief home's `chief:<id>`, where the Chief runs its subagents): their chat tabs read
    /// their titles and states here as this Mac's do.
    public var mirroredHosts: Set<String> = []
    /// The watch is up and the states are acpmux's: false before its first page and after it
    /// closes, when a chat with no state may still be working.
    public var watching = false
    /// A session's running turn ended (working to anything else; the watch closing is not an
    /// end), this Mac's or an acpmux peer's row of it (that row's working to anything else). The
    /// app rings the chat's pane until the person goes into it, as a terminal agent's
    /// notification does: acpmux reads a turn that ends in a shown chat at once (cx-n8ou).
    @ObservationIgnored public var onTurnEnded: ((String) -> Void)?
    /// Also told when a session's running turn ends, with its folder (`cwd`, when known): the diff
    /// viewer precomputes that repository's diff once someone can see the chat, before anyone clicks
    /// (DiffPageRuntime+Warm.swift; a chat nobody sees owes it until it shows, `AgentPaneOwedWork`).
    @ObservationIgnored public var turnEndedObservers: [(_ session: String, _ folder: String?) -> Void] = []

    public init() {}

    // MARK: Writes (the watch feed)

    /// Sets one session's turn state; writes only a change.
    public func setState(_ state: AgentTurnState?, session: String) {
        let record = record(session)
        guard record.state != state else { return }
        if record.state == .working { workingSessions -= 1 }
        if state == .working { workingSessions += 1 }
        record.state = state
        stateRevision &+= 1
    }

    /// Tells the turn-end hooks that `session`'s running turn ended.
    private func turnEnded(_ session: String, folder: String?) {
        onTurnEnded?(session)
        for observer in turnEndedObservers { observer(session, folder) }
    }

    /// Sets one session's facts from a `_acpmux/session_changed`; writes only what changed.
    /// `recordsTimeline` false (the watch closing) notes no moment: nothing happened to the chat.
    /// A push of acpmux peer `peerName`'s row (`peer`: that row, nil when the peer purged it) writes that row,
    /// never this Mac's state or timeline of the session id: session ids are each daemon's own, and another
    /// machine's turn is not this Mac's (design audit 2026-11-18 finding 7). Its chat facts (title, last message)
    /// stay as before: the Chief pet reads a peer's chat's last message by session id.
    public func apply(session: String, sessionName: String? = nil, state: AgentTurnState?, lastMessage: String?, muted: Bool, title: String?,
                      generatedTitle: String? = nil, identity: AgentSessionIdentity? = nil, detail: AgentChatDetail?, recordsTimeline: Bool = true,
                      source: String = AgentTurnStateStore.localSource, peer: AgentPeerRow? = nil, peerName: String? = nil) {
        let held = record(session)
        held.source = source
        if let name = peerName ?? peer?.name {
            if recordsTimeline, held.peers[name]?.state == .working, peer?.state != .working { turnEnded(session, folder: (detail ?? held.detail)?.cwd) }
            if held.peers[name] != peer { held.peers[name] = peer }
            writeFacts(held, sessionName: sessionName, lastMessage: lastMessage, muted: muted, title: title, generatedTitle: generatedTitle,
                       identity: identity, detail: detail)
            return
        }
        if recordsTimeline, held.state == .working, state != .working { turnEnded(session, folder: (detail ?? held.detail)?.cwd) }
        if recordsTimeline {
            let nowMs = UInt64((Date().timeIntervalSince1970 * 1000).rounded())
            for event in AgentTimeline.chatEvents(from: held.state, held.detail, to: state, detail, nowMs: nowMs) {
                held.timeline.append(event)
            }
        }
        setState(state, session: session)
        writeFacts(held, sessionName: sessionName, lastMessage: lastMessage, muted: muted, title: title, generatedTitle: generatedTitle,
                   identity: identity, detail: detail)
        // A peer's row (returned above) is another daemon's session; a closing watch (no timeline) knows nothing
        // new, so its archived chats stay listed while it reconnects.
        if detail != nil || recordsTimeline {
            archivedChats.set(session, detail.flatMap { detail in
                guard detail.archived else { return nil }
                return ArchivedChat(id: session, title: generatedTitle ?? title ?? sessionName ?? session, cwd: detail.cwd,
                                    archivedAtMs: detail.archivedAtMs, source: source)
            })
        }
    }

    /// Writes a record's chat facts; only what changed.
    private func writeFacts(_ record: Session, sessionName: String?, lastMessage: String?, muted: Bool, title: String?, generatedTitle: String?,
                            identity: AgentSessionIdentity?, detail: AgentChatDetail?) {
        if record.lastMessage != lastMessage { record.lastMessage = lastMessage }
        if record.muted != muted { record.muted = muted }
        if record.title != title { record.title = title }
        if record.generatedTitle != generatedTitle { record.generatedTitle = generatedTitle }
        if record.sessionName != sessionName { record.sessionName = sessionName }
        if record.identity != identity {
            record.identity = identity
            record.iconArt = nil
        }
        if record.detail != detail { record.detail = detail }
    }

    /// Replaces every session of `source`'s watch with its page's; writes only what changed.
    /// Sessions another watch wrote stay as they are, and so do the `keeping` ones and the
    /// `keepingPeers` rows (by session id, then peer): a change pushed while the page's later
    /// parts were read is newer than the page. Every other peer row of such a session is the page's.
    public func replace(states: AgentTurnStates, lastMessages: [String: String], muted: Set<String>,
                        titles: [String: String], generatedTitles: [String: String] = [:], sessionNames: [String: String] = [:],
                        identities: [String: AgentSessionIdentity] = [:], details: [String: AgentChatDetail],
                        source: String = AgentTurnStateStore.localSource, peers: [String: [String: AgentPeerRow]] = [:], keeping: Set<String> = [],
                        keepingPeers: [String: Set<String>] = [:]) {
        let own = sessions.compactMap { $0.value.source == source ? $0.key : nil }
        let listed = Set(states.bySession.keys).union(lastMessages.keys).union(muted)
            .union(titles.keys).union(generatedTitles.keys).union(sessionNames.keys).union(identities.keys).union(details.keys).union(peers.keys)
        let ids = listed.union(own)
        defer {
            // A session of this watch that its whole list no longer has: acpmux dropped it.
            for id in own where !listed.contains(id) && !keeping.contains(id) && keepingPeers[id] == nil { sessionEnded(id) }
        }
        for id in ids.union(keepingPeers.keys) {
            if !keeping.contains(id), keepingPeers[id] == nil {
                apply(session: id, sessionName: sessionNames[id], state: states[id], lastMessage: lastMessages[id], muted: muted.contains(id),
                      title: titles[id], generatedTitle: generatedTitles[id], identity: identities[id], detail: details[id], source: source)
            }
            var rows = peers[id] ?? [:]
            let held = record(id)
            for name in keepingPeers[id] ?? [] { rows[name] = held.peers[name] }
            guard held.peers != rows else { continue }
            // A peer's turn that ran ended when the page has its row no longer working (or gone).
            if held.peers.contains(where: { $0.value.state == .working && rows[$0.key]?.state != .working }) {
                turnEnded(id, folder: (details[id] ?? held.detail)?.cwd)
            }
            held.peers = rows
        }
    }

    /// Lays a usage read's numbers (`_acpmux/sessions` with `usage: true`, by session id) over
    /// `source`'s sessions, leaving every other fact as it is; writes only what changed. A session
    /// the store does not hold from `source` is skipped: the watch has not listed it.
    public func applyUsage(_ usage: [String: AgentChatDetail], source: String = AgentTurnStateStore.localSource) {
        for (id, numbers) in usage {
            guard let record = sessions[id], record.source == source else { continue }
            let detail = (record.detail ?? AgentChatDetail()).withUsage(of: numbers)
            if record.detail != detail { record.detail = detail }
        }
    }

    /// `source`'s watch closed: nothing live is known of its sessions. Titles stay: a tab keeps
    /// reading as its chat while the watch reconnects.
    public func clearLive(source: String = AgentTurnStateStore.localSource) {
        for (id, record) in sessions where record.source == source {
            apply(session: id, sessionName: record.sessionName, state: nil, lastMessage: nil, muted: false, title: record.title,
                  generatedTitle: record.generatedTitle, identity: record.identity, detail: nil, recordsTimeline: false, source: source)
            if !record.peers.isEmpty { record.peers = [:] }
        }
    }

    /// Peer `peer` purged its session `session`: its row goes (another peer's row of that id stays), and a
    /// record that held only that row knows nothing more. ``apply`` may have removed the row already.
    public func removePeerRow(_ peer: String, session: String) {
        guard let record = sessions[session] else { return }
        if record.peers[peer] != nil { record.peers[peer] = nil }
        if record.isBlank { sessions[session] = nil }
    }
}
