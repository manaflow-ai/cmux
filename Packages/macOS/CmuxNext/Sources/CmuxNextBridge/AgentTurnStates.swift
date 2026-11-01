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

    public init(model: String? = nil, turnStartedAtMs: UInt64? = nil, prompt: String? = nil,
                laneState: String? = nil, laneSinceMs: UInt64? = nil, cwd: String? = nil,
                contextTokens: Int? = nil, contextWindow: Int? = nil, costUsd24h: Double? = nil, promptIsNotice: Bool = false,
                subagentsRunning: Int = 0, subagentNames: [String] = [], commandsRunning: Int = 0) {
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
        let detail = AgentChatDetail(model: text(summary["model"]), turnStartedAtMs: (turn?["startedAt"] as? NSNumber)?.uint64Value,
                                     prompt: text(turn?["prompt"]), laneState: text(lane?["state"]),
                                     laneSinceMs: (lane?["since"] as? NSNumber)?.uint64Value, cwd: text(summary["cwd"]),
                                     contextTokens: tokens(usage?["contextTokens"]),
                                     contextWindow: tokens(usage?["contextWindow"]).flatMap { $0 > 0 ? $0 : nil },
                                     costUsd24h: amount(usage?["costUsd24h"]),
                                     promptIsNotice: turn?["notice"] as? Bool == true,
                                     subagentsRunning: count(summary["subagentsRunning"]),
                                     subagentNames: (summary["subagentNames"] as? [Any] ?? []).compactMap(text),
                                     commandsRunning: count(summary["commandsRunning"]))
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
        -> (session: String, state: AgentTurnState?, lastMessage: String?, muted: Bool, title: String?, generatedTitle: String?, sessionName: String?)? {
        guard let id = params["sessionId"] as? String else { return nil }
        if params["kind"] as? String == "purged" { return (id, nil, nil, false, nil, nil, nil) }
        guard let summary = params["session"] as? [String: Any] else { return nil }
        let session = summary["sessionId"] as? String ?? id
        return (session, AgentTurnState.of(summary: summary), lastMessage(summary), muted(summary),
                title(summary), title(summary, includingPrompt: false), sessionName(summary))
    }

    /// A summary's chat title as the page names it (sessionList.ts `sessionTitle`): the name the
    /// user gave, else the agent's title, else the first prompt. A name acpmux generated from the
    /// harness or its family (`claude-sr`, `claude-sr-2`, `codex-fork`) is no title, nor a Chief's
    /// session name (`optchat-sub-2e448bc2-a345`). A title or prompt reads as its gist
    /// (``promptGist(_:)``): a Chief subagent's `<chat>` view never names its tab. The latest
    /// prompt only stands in while acpmux reports no title at all. Nil when the chat has none yet.
    public static func title(_ summary: [String: Any], includingPrompt: Bool = true) -> String? {
        if includingPrompt, let name = sessionName(summary) { return name }
        if !includingPrompt {
            // acpmux publishes the first prompt as `title` before its title
            // request completes. Only a source that names a real chat title
            // may feed durable workspace auto-naming; an absent source is an
            // older daemon and is intentionally treated as unknown.
            let source = summary["titleSource"] as? String
            guard let source, ["harness", "generated", "adopted"].contains(source) else { return nil }
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

    public subscript(session: String) -> AgentTurnState? { states[session] }

    /// Every session's state.
    public var bySession: [String: AgentTurnState] { states }

    private mutating func upsert(_ summary: [String: Any]) {
        guard let id = summary["sessionId"] as? String else { return }
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
        /// The last message (expanded sidebar rows, cx-13w3.1).
        var lastMessage: String?
        var muted = false
        /// The chat's title (`AgentTurnStates.title`), for a chat tab the user has not named.
        var title: String?
        /// The chat's real title, excluding its session name and first prompt.
        var generatedTitle: String?
        /// The launcher/session name, when it is user-readable rather than harness-generated.
        var sessionName: String?
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
    }

    /// The source of the app's own acpmux watch.
    public nonisolated static let localSource = "local"

    /// The records by session id; not observed itself (a reader observes the record it reads).
    @ObservationIgnored var sessions: [String: Session] = [:]
    /// Bumped by every turn state change of any session: for a reader that
    /// follows all of them (one read, no walk).
    public private(set) var stateRevision: UInt64 = 0
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
    /// end). The app rings the chat's pane until the person goes into it, as a terminal agent's
    /// notification does: acpmux reads a turn that ends in a shown chat at once (cx-n8ou).
    @ObservationIgnored public var onTurnEnded: ((String) -> Void)?

    public init() {}

    /// The record of `session`, made empty on first use (an unobserved write).
    private func record(_ session: String) -> Session {
        if let record = sessions[session] { return record }
        let record = Session()
        sessions[session] = record
        return record
    }

    private func local(_ ref: AgentSessionRef) -> Session? {
        guard let session = ref.session, isMirrored(ref.host) else { return nil }
        return record(session)
    }

    /// Whether a chat of `host` has its facts here: this Mac's or a mirrored acpmux's. Every
    /// Chief home on this Mac (the default one and each named Chief, `chief:<own home id>`) runs
    /// its subagents in the one Chief acpmux that the mirrored watch reads, so any Chief host
    /// counts once that watch exists; a session id another machine's Chief holds has no record.
    private func isMirrored(_ host: String) -> Bool {
        host == localHost || mirroredHosts.contains(host)
            || (!mirroredHosts.isEmpty && host.hasPrefix(Self.chiefHostPrefix))
    }

    /// The start of every Chief home's tab host (`ChiefHome.tabHostPrefix`).
    private nonisolated static let chiefHostPrefix = "chief:"

    // MARK: Writes (the watch feed)

    /// Sets one session's turn state; writes only a change.
    public func setState(_ state: AgentTurnState?, session: String) {
        let record = record(session)
        guard record.state != state else { return }
        record.state = state
        stateRevision &+= 1
    }

    /// Sets one session's facts from a `_acpmux/session_changed`; writes only what changed.
    /// `recordsTimeline` false (the watch closing) notes no moment: nothing happened to the chat.
    public func apply(session: String, sessionName: String? = nil, state: AgentTurnState?, lastMessage: String?, muted: Bool, title: String?,
                      generatedTitle: String? = nil, detail: AgentChatDetail?, recordsTimeline: Bool = true,
                      source: String = AgentTurnStateStore.localSource) {
        let held = record(session)
        held.source = source
        if recordsTimeline, held.state == .working, state != .working { onTurnEnded?(session) }
        if recordsTimeline {
            let nowMs = UInt64((Date().timeIntervalSince1970 * 1000).rounded())
            for event in AgentTimeline.chatEvents(from: held.state, held.detail, to: state, detail, nowMs: nowMs) {
                held.timeline.append(event)
            }
        }
        setState(state, session: session)
        let record = record(session)
        if record.lastMessage != lastMessage { record.lastMessage = lastMessage }
        if record.muted != muted { record.muted = muted }
        if record.title != title { record.title = title }
        if record.generatedTitle != generatedTitle { record.generatedTitle = generatedTitle }
        if record.sessionName != sessionName { record.sessionName = sessionName }
        if record.detail != detail { record.detail = detail }
    }

    /// Replaces every session of `source`'s watch with its page's; writes only what changed.
    /// Sessions another watch wrote stay as they are.
    public func replace(states: AgentTurnStates, lastMessages: [String: String], muted: Set<String>,
                        titles: [String: String], generatedTitles: [String: String] = [:], sessionNames: [String: String] = [:], details: [String: AgentChatDetail],
                        source: String = AgentTurnStateStore.localSource) {
        let own = sessions.compactMap { $0.value.source == source ? $0.key : nil }
        let ids = Set(own).union(states.bySession.keys).union(lastMessages.keys).union(muted)
            .union(titles.keys).union(generatedTitles.keys).union(sessionNames.keys).union(details.keys)
        for id in ids {
            apply(session: id, sessionName: sessionNames[id], state: states[id], lastMessage: lastMessages[id], muted: muted.contains(id),
                  title: titles[id], generatedTitle: generatedTitles[id], detail: details[id], source: source)
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
                  generatedTitle: record.generatedTitle, detail: nil, recordsTimeline: false, source: source)
        }
    }

    // MARK: Reads

    /// The turn state of the session an agent chat tab shows.
    public func state(for ref: AgentSessionRef) -> AgentTurnState? { local(ref)?.state }

    /// The last message of the session an agent chat tab shows.
    public func lastMessage(for ref: AgentSessionRef) -> String? { local(ref)?.lastMessage }

    /// The recent moments of the chat an agent chat tab shows (u3320); empty off this Mac.
    public func timeline(for ref: AgentSessionRef) -> AgentTimeline {
        guard let session = ref.session, isMirrored(ref.host) else { return AgentTimeline() }
        return sessions[session]?.timeline ?? AgentTimeline()
    }

    /// The model and running turn of the chat an agent chat tab shows; nil off this Mac.
    public func detail(for ref: AgentSessionRef) -> AgentChatDetail? { local(ref)?.detail }

    /// The title of the chat an agent chat tab shows; nil when it has none yet or is not on
    /// this Mac.
    public func title(for ref: AgentSessionRef) -> String? { local(ref)?.title }

    /// The launcher/session name, when it is user-readable.
    public func sessionName(for ref: AgentSessionRef) -> String? { local(ref)?.sessionName }

    /// The chat's real title, excluding its session name and first prompt.
    public func generatedTitle(for ref: AgentSessionRef) -> String? { local(ref)?.generatedTitle }

    /// Whether the chat an agent chat tab shows has its notifications muted; nil when
    /// the chat is not on this Mac (its acpmux runs elsewhere) or not known yet.
    public func isMuted(_ ref: AgentSessionRef) -> Bool? { local(ref)?.muted }
}
