import Foundation

/// One agent session's turn facts, folded from its lifecycle hooks in arrival order.
///
/// The app keeps one value per pane and session. It answers what the hooks alone
/// know: whether a turn is running, which tool calls are open, and whether the
/// turn ended with background work or an open question.
public struct AgentHookActivityState: Sendable, Equatable {
    /// A lifecycle hook reduced to what activity tracking needs.
    public enum Event: Sendable, Equatable {
        case sessionStart
        case promptSubmit
        /// `id` is the hook's `tool_use_id`, when present.
        case preToolUse(id: String?, tool: AgentActivity.Tool)
        case postToolUse(id: String?, toolName: String?)
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
    public private(set) var lastToolFinished = false
    public private(set) var backgroundWork = false
    public private(set) var awaitingInput = false
    public private(set) var pendingQuestion = false
    public private(set) var ended = false
    /// When the latest transition happened.
    public private(set) var since: Date?
    /// When the running turn's prompt was submitted; nil between turns.
    public private(set) var turnStartedAt: Date?
    private var openTools: [OpenTool] = []

    public init() {}

    /// The call that best describes what the agent is doing now: the newest
    /// open non-subagent tool, else the newest open subagent launcher.
    public var openTool: AgentActivity.Tool? {
        openTools.last { !AgentActivityClassifier.subagentTools.contains($0.tool.name) }?.tool
            ?? openTools.last?.tool
    }

    public mutating func apply(_ event: Event, at date: Date) {
        since = date
        switch event {
        case .sessionStart:
            self = AgentHookActivityState()
            since = date
        case .promptSubmit:
            turnActive = true
            turnStartedAt = date
            lastToolFinished = false
            backgroundWork = false
            awaitingInput = false
            pendingQuestion = false
            ended = false
            openTools.removeAll()
        case .preToolUse(let id, let tool):
            turnActive = true
            lastToolFinished = false
            awaitingInput = false
            if Self.questionTools.contains(tool.name) {
                pendingQuestion = true
                return
            }
            if let id { openTools.removeAll { $0.id == id } }
            openTools.append(OpenTool(id: id, tool: tool))
            if openTools.count > Self.maximumOpenTools {
                openTools.removeFirst(openTools.count - Self.maximumOpenTools)
            }
        case .postToolUse(let id, let toolName):
            turnActive = true
            lastToolFinished = true
            if let toolName, Self.questionTools.contains(toolName) {
                pendingQuestion = false
                return
            }
            if let id, let index = openTools.lastIndex(where: { $0.id == id }) {
                openTools.remove(at: index)
            } else if let toolName, let index = openTools.lastIndex(where: { $0.id == nil && $0.tool.name == toolName }) {
                openTools.remove(at: index)
            }
        case .stop(let background):
            turnActive = false
            turnStartedAt = nil
            lastToolFinished = false
            pendingQuestion = false
            awaitingInput = false
            backgroundWork = background
            openTools.removeAll()
        case .notification(let idlePrompt):
            if idlePrompt, !turnActive {
                awaitingInput = true
            }
        case .sessionEnd:
            self = AgentHookActivityState()
            ended = true
            since = date
        }
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
    /// - Returns: The event and the hook's session id, or nil when the
    ///   subcommand carries no activity fact or the payload is not a JSON object.
    public static func parse(subcommand: String, payload: Data) -> (event: Self, sessionID: String?)? {
        guard subcommands.contains(subcommand),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        let sessionID = string(object, ["session_id", "sessionId"])
        let event: Self
        switch subcommand {
        case "session-start":
            event = .sessionStart
        case "prompt-submit":
            event = .promptSubmit
        case "pre-tool-use":
            guard let name = string(object, ["tool_name", "toolName"]) else { return nil }
            let input = object["tool_input"] as? [String: Any] ?? object["toolInput"] as? [String: Any] ?? [:]
            event = .preToolUse(
                id: string(object, ["tool_use_id", "toolUseId"]),
                tool: AgentActivity.Tool(name: name, command: commandSummary(toolName: name, input: input))
            )
        case "post-tool-use":
            event = .postToolUse(
                id: string(object, ["tool_use_id", "toolUseId"]),
                toolName: string(object, ["tool_name", "toolName"])
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
