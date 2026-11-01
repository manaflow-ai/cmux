public import Foundation

/// One acpmux session's lane (cx-v9k2f): an agent chat on this Mac or on an acpmux peer it
/// mirrors, with the state acpmux decided for it (the summary's `lane`). The Priority view, the
/// Chief item and the session tree read it; acpmux owns the decision.
public nonisolated struct AgentActivityLane: Hashable, Sendable, Identifiable {
    /// What the session is doing, as acpmux decided it.
    public enum State: String, Sendable {
        /// A turn runs.
        case working
        /// A permission or question waits for the person.
        case input
        /// Nothing runs; waiting for its next prompt.
        case idle
        /// The last turn failed (`error` says why, e.g. "Credit balance too low").
        case failed
        /// The agent process is gone without an answer.
        case lost
    }

    public let id: String
    /// The session's acpmux name (`<peer>/<name>` for a peer's).
    public let name: String
    /// acpmux's masked title (`lane.title`), else its name.
    public let title: String
    /// The acpmux peer that owns it; nil on this Mac.
    public let peer: String?
    /// The existing cmux workspace binding for this agent session, when the
    /// ACPmux summary carries one.
    public let workspaceID: String?
    /// Its `mux.parent` tag: the coordinator that started it.
    public let parent: String?
    public let state: State
    /// Since when it has been in `state`.
    public let since: Date?
    /// The last turn's error text when `failed` or `lost`.
    public let error: String?
    /// The harness that runs it, as acpmux names it ("claude", "codex").
    public let harness: String?
    /// What it is doing now, one line (hq#2509): the lane's `step`, which acpmux masks secrets in.
    public let step: String?
    /// The running turn's prompt, for distinguishing prompt-derived lane steps from status.
    public let turnPrompt: String?
    /// Activity and plan metadata, independent of the prompt-derived lane step.
    public let turnActivity: String?
    public let turnPlanStep: String?
    /// A turn ended while no client showed the chat (the summary's `unread`); showing it clears it.
    public let unread: Bool
    /// The session folder's name (the last part of `cwd`), the Priority view's project tag.
    public let project: String?
    /// The session whose agent started this one (acpmux `spawnedBy`, one level): the sidebar's
    /// session tree lists its workspace under that session's.
    public let spawnedBy: String?
    /// acpmux classifies agent-started sessions as requiring an opened tab before a sidebar row.
    public let sidebarRequiresOpen: Bool
    /// The session's folder: the sidebar's session tree reads its branch's pull request there.
    public let cwd: String?
    /// The pull requests its `gh pr create` calls opened (acpmux `pullRequests`, their URLs): the
    /// sidebar's session tree counts them beside its folder's branch's.
    public let pullRequests: [String]
    /// The acpmux chat index key (`harness:sessionId`) of the chat the session continues: its
    /// family's index harness and the agent's own session id. Nil for a family the index has none
    /// of, or before the agent named its session. The session tree's chat history leaves it out.
    public let chat: String?
    /// When the session last changed (its last output), when the summary carries it: the Chief
    /// view gallery's "time since last output".
    public let updatedAt: Date?
    /// When the session started, when the summary carries it.
    public let createdAt: Date?
    /// What a read or snooze mark on the lane holds for beside its state, when `since` cannot say
    /// it: another machine's chat tab's notice (``AgentPriorityMarks``). Nil: its `since`.
    public let markKey: String?
    /// The usage rules the session breaks, one line each (acpmux `usageWarnings[].text`: no
    /// autocompact cap, a context or a subagent rate above its limit). Empty when it breaks none.
    public let usageWarnings: [String]

    public init(id: String, name: String, title: String, peer: String?, parent: String?, state: State, since: Date?, error: String?,
                workspaceID: String? = nil, harness: String? = nil, step: String? = nil, unread: Bool = false, project: String? = nil,
                spawnedBy: String? = nil, cwd: String? = nil, pullRequests: [String] = [], chat: String? = nil,
                updatedAt: Date? = nil, createdAt: Date? = nil, markKey: String? = nil, usageWarnings: [String] = [], sidebarRequiresOpen: Bool = false,
                turnPrompt: String? = nil, turnActivity: String? = nil, turnPlanStep: String? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.peer = peer
        self.workspaceID = workspaceID
        self.parent = parent
        self.state = state
        self.since = since
        self.error = error
        self.harness = harness
        self.step = step
        self.turnPrompt = turnPrompt
        self.turnActivity = turnActivity
        self.turnPlanStep = turnPlanStep
        self.unread = unread
        self.project = project
        self.spawnedBy = spawnedBy
        self.sidebarRequiresOpen = sidebarRequiresOpen
        self.cwd = cwd
        self.pullRequests = pullRequests
        self.chat = chat
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.markKey = markKey
        self.usageWarnings = usageWarnings
    }

    /// A person should look: it waits on them, failed or was lost.
    public var needsAttention: Bool { state == .input || state == .failed || state == .lost }

    /// The `mux.parent` tag acpmux sessions started by a coordinator carry.
    public static let parentTag = "mux.parent"

    /// The lane of one `_acpmux/watch` / `session_changed` summary; nil when acpmux decided none
    /// (a closed session, or an acpmux from before `lane`). `id` names the session when the
    /// summary does not (a `session_changed` carries it beside the summary).
    public static func of(summary: [String: Any], id fallback: String? = nil) -> AgentActivityLane? {
        guard let id = summary["sessionId"] as? String ?? fallback, let lane = summary["lane"] as? [String: Any],
              let raw = lane["state"] as? String, let state = State(rawValue: raw) else { return nil }
        let name = summary["name"] as? String ?? id
        let since = (lane["since"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let error = (lane["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let parent = ((summary["tags"] as? [String: Any])?[parentTag] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let workspaceID = (summary["workspaceId"] as? String) ?? (summary["workspace_id"] as? String)
        let harness = (summary["harness"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // The masked step may still be a folded/truncated prompt. Keep its provenance
        // so the sidebar can show activity instead without changing other lane surfaces.
        let turn = summary["turn"] as? [String: Any]
        let step = (lane["step"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let title = (lane["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let unread = (summary["unread"] as? Bool) ?? false
        let project = (summary["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        return AgentActivityLane(id: id, name: name, title: title ?? name, peer: summary["peer"] as? String, parent: parent,
                                 state: state, since: since, error: error, workspaceID: workspaceID,
                                 harness: harness, step: step, unread: unread, project: project,
                                 spawnedBy: nonEmpty(summary["spawnedBy"]), cwd: nonEmpty(summary["cwd"]),
                                 pullRequests: (summary["pullRequests"] as? [Any] ?? []).compactMap { nonEmpty($0) },
                                 chat: chatKey(family: nonEmpty(summary["family"]), agentSession: nonEmpty(summary["agentSessionId"])),
                                 updatedAt: date(summary["updatedMs"] ?? summary["updatedAt"]),
                                 createdAt: date(summary["createdMs"] ?? summary["createdAt"]),
                                 usageWarnings: (summary["usageWarnings"] as? [[String: Any]] ?? []).compactMap { nonEmpty($0["text"]) },
                                 sidebarRequiresOpen: (lane["requiresOpen"] as? Bool) ?? false,
                                 turnPrompt: turn?["prompt"] as? String,
                                 turnActivity: nonEmpty(turn?["activity"]), turnPlanStep: nonEmpty(turn?["planStep"]))
    }

    /// A summary's epoch-milliseconds field as a date; nil when absent or not a number.
    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? NSNumber, value.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue / 1000)
    }

    /// acpmux's `session_chat_key`: only the claude and codex families are indexed.
    static func chatKey(family: String?, agentSession: String?) -> String? {
        guard let agentSession else { return nil }
        return switch family {
        case "claude": "claude-code:" + agentSession
        case "codex": "codex:" + agentSession
        default: nil
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
}
