import Foundation

/// One agent session's turn facts, folded from its lifecycle hooks in arrival order.
///
/// The app keeps one value per pane and session. It answers what the hooks alone
/// know: whether a turn is running, which tool calls are open, and whether the
/// turn ended with background work or an open question. When the hooks cannot
/// tell, the state keeps the busier reading.
public struct AgentHookActivityState: Sendable, Equatable {
    /// A lifecycle hook reduced to what activity tracking needs.
    public enum Event: Sendable, Equatable {
        /// `fresh` is true for a new or cleared conversation (`startup`, `clear`).
        /// A compaction or resume continues the running turn.
        case sessionStart(fresh: Bool)
        case promptSubmit
        /// `id` is the hook's `tool_use_id`; `subagent` marks a call made inside a subagent.
        case preToolUse(id: String?, tool: AgentActivity.Tool, subagent: Bool)
        /// Also sent for a failed, denied or interrupted call (PostToolUseFailure).
        case postToolUse(id: String?, toolName: String?, subagent: Bool)
        case stop(backgroundWork: Bool)
        /// `idlePrompt` is true for the "waiting for your input" notification.
        case notification(idlePrompt: Bool)
        case sessionEnd
    }

    /// Tools that open a question or plan approval instead of running.
    public static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Open calls kept per session; older ones are dropped first.
    public static let maximumOpenTools = 16

    private struct OpenTool: Sendable, Equatable {
        var id: String?
        var tool: AgentActivity.Tool
    }

    public private(set) var turnActive = false
    /// Whether a turn boundary (prompt, Stop, idle prompt, fresh start) was seen.
    /// Without one, `turnActive` says nothing and the registry decides.
    public private(set) var knowsTurnBoundary = false
    public private(set) var lastToolFinished = false
    public private(set) var backgroundWork = false
    public private(set) var awaitingInput = false
    public private(set) var pendingQuestion = false
    public private(set) var ended = false
    /// When the state last changed.
    public private(set) var since: Date?
    /// When the running turn's prompt was submitted; nil between turns.
    public private(set) var turnStartedAt: Date?
    /// When the agent last went idle (Stop, idle prompt, fresh start); nil during a turn.
    public private(set) var idleSince: Date?
    private var openTools: [OpenTool] = []

    public init() {}

    /// The call that best describes what the agent is doing now: the newest
    /// open non-subagent tool, else the newest open subagent launcher.
    public var openTool: AgentActivity.Tool? {
        openTools.last { !AgentActivityClassifier.subagentTools.contains($0.tool.name) }?.tool
            ?? openTools.last?.tool
    }

    /// Commands started before this cannot belong to the current turn or idle period.
    public var processesNotBefore: Date? {
        turnActive ? turnStartedAt : idleSince
    }

    public mutating func apply(_ event: Event, at date: Date) {
        let before = self
        fold(event, at: date)
        var unchanged = self
        unchanged.since = before.since
        since = unchanged == before ? before.since : date
    }

    private mutating func fold(_ event: Event, at date: Date) {
        switch event {
        case .sessionStart(let fresh):
            ended = false
            guard fresh else { return }
            self = AgentHookActivityState()
            knowsTurnBoundary = true
            idleSince = date
        case .promptSubmit:
            turnActive = true
            knowsTurnBoundary = true
            turnStartedAt = date
            idleSince = nil
            lastToolFinished = false
            backgroundWork = false
            awaitingInput = false
            pendingQuestion = false
            ended = false
            openTools.removeAll()
        case .preToolUse(let id, var tool, let subagent):
            if Self.questionTools.contains(tool.name) {
                pendingQuestion = true
                return
            }
            pendingQuestion = false
            if !subagent { lastToolFinished = false }
            tool.startedAt = tool.startedAt ?? date
            if let id { openTools.removeAll { $0.id == id } }
            openTools.append(OpenTool(id: id, tool: tool))
            if openTools.count > Self.maximumOpenTools {
                openTools.removeFirst(openTools.count - Self.maximumOpenTools)
            }
        case .postToolUse(let id, let toolName, let subagent):
            if let toolName, Self.questionTools.contains(toolName) {
                pendingQuestion = false
                return
            }
            pendingQuestion = false
            closeTool(id: id, name: toolName)
            if turnActive, !subagent { lastToolFinished = true }
        case .stop(let background):
            endTurn(at: date)
            pendingQuestion = false
            backgroundWork = background
        case .notification(let idlePrompt):
            // Claude asks for input only once the turn is over; an interrupted
            // or failed call never reports its end otherwise. An open question
            // stays open: that is what the prompt may be waiting on.
            guard idlePrompt else { return }
            endTurn(at: date)
            awaitingInput = true
        case .sessionEnd:
            self = AgentHookActivityState()
            ended = true
            knowsTurnBoundary = true
        }
    }

    private mutating func endTurn(at date: Date) {
        turnActive = false
        knowsTurnBoundary = true
        turnStartedAt = nil
        idleSince = date
        lastToolFinished = false
        awaitingInput = false
        openTools.removeAll()
    }

    /// Closes by `tool_use_id`. A post without one (compacted away) closes the
    /// newest open call of the same tool; a post whose id matches nothing closes
    /// the newest same-named call that never had an id.
    private mutating func closeTool(id: String?, name: String?) {
        if let id, let index = openTools.lastIndex(where: { $0.id == id }) {
            openTools.remove(at: index)
            return
        }
        guard let name else { return }
        let index = openTools.lastIndex { open in
            open.tool.name == name && (id == nil || open.id == nil)
        }
        if let index { openTools.remove(at: index) }
    }
}

extension AgentHookActivityState.Event {
    /// The hook subcommands that carry an activity fact.
    public static let subcommands: Set<String> = [
        "session-start", "prompt-submit", "pre-tool-use", "post-tool-use", "stop", "notification", "session-end",
    ]

    /// Longest command or summary kept for an open tool.
    public static let maximumCommandLength = 200

    /// Parses one queued hook (`cmux hooks <agent> <subcommand>`) payload.
    ///
    /// - Parameter relayBacked: The hook came from a remote host through the relay.
    ///   Remote daemons send no PostToolUse, so a remote question would never
    ///   close; the Feed overlay already reports remote questions and permissions.
    /// - Returns: The event and the hook's session id, or nil when the
    ///   subcommand carries no activity fact or the payload is not a JSON object.
    public static func parse(
        subcommand: String,
        payload: Data,
        relayBacked: Bool = false
    ) -> (event: Self, sessionID: String?)? {
        guard let parsed = parseEvent(subcommand: subcommand, payload: payload) else { return nil }
        if relayBacked, case .preToolUse(_, let tool, _) = parsed.event,
           AgentHookActivityState.questionTools.contains(tool.name) {
            return nil
        }
        return parsed
    }

    private static func parseEvent(subcommand: String, payload: Data) -> (event: Self, sessionID: String?)? {
        guard subcommands.contains(subcommand),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        let sessionID = string(object, ["session_id", "sessionId"])
        let subagent = string(object, ["agent_id", "agentId"]) != nil
        let event: Self
        switch subcommand {
        case "session-start":
            // Only a new or cleared conversation starts clean. A compaction,
            // resume or unknown source keeps whatever may still be running.
            let source = string(object, ["source"])?.lowercased()
            event = .sessionStart(fresh: source == "startup" || source == "clear")
        case "prompt-submit":
            event = .promptSubmit
        case "pre-tool-use":
            guard let name = string(object, ["tool_name", "toolName"]) else { return nil }
            let input = object["tool_input"] as? [String: Any] ?? object["toolInput"] as? [String: Any] ?? [:]
            event = .preToolUse(
                id: string(object, ["tool_use_id", "toolUseId"]),
                tool: AgentActivity.Tool(name: name, command: commandSummary(toolName: name, input: input)),
                subagent: subagent
            )
        case "post-tool-use":
            event = .postToolUse(
                id: string(object, ["tool_use_id", "toolUseId"]),
                toolName: string(object, ["tool_name", "toolName"]),
                subagent: subagent
            )
        case "stop":
            event = .stop(backgroundWork: hasBackgroundWork(object))
        case "notification":
            let type = string(object, ["notification_type", "notificationType"])
            event = .notification(idlePrompt: type == "idle_prompt")
        case "session-end":
            event = .sessionEnd
        default:
            return nil
        }
        return (event, sessionID)
    }

    /// The Bash command, or the first descriptive input field, on one line.
    static func commandSummary(toolName: String, input: [String: Any]) -> String? {
        let keys = ["command", "cmd", "file_path", "path", "pattern", "url", "query", "description", "prompt"]
        for key in keys {
            guard let value = input[key] as? String else { continue }
            let line = value.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !line.isEmpty else { continue }
            return line.count > maximumCommandLength
                ? String(line.prefix(maximumCommandLength - 1)) + "…"
                : line
        }
        return nil
    }

    /// Claude's Stop payload lists running background tasks and pending
    /// session crons. Absent keys (older clients) mean none.
    static func hasBackgroundWork(_ object: [String: Any]) -> Bool {
        if let crons = object["session_crons"] as? [Any], !crons.isEmpty { return true }
        if let tasks = object["background_tasks"] as? [[String: Any]] {
            return tasks.contains { $0["status"] as? String == "running" }
        }
        return false
    }

    private static func string(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
