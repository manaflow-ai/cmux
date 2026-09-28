import Foundation

/// What an agent is doing right now, precise enough to answer "is it truly idle?".
///
/// ``ChatAgentState`` is the coarse lifecycle the sidebar shows. This splits its
/// `working` and `needsInput` cases into the activities a restart, update or
/// hibernation decision needs to tell apart. Field names are the wire names used
/// by the agents view and the updater.
public struct AgentActivity: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// The turn is over and nothing is pending.
        case idle
        /// The turn is over and the prompt waits on a human.
        case awaitingInput = "awaiting_input"
        /// An AskUserQuestion or plan approval is open.
        case question
        /// Blocked on a permission request.
        case permission
        /// Mid-turn with no tool running: a model request is in flight.
        case thinking
        /// Inside a tool call; see ``AgentActivity/tool``.
        case tool
        /// Inside a Task call whose subagents are running.
        case subagents
        /// The turn stopped, but a background task or scheduled wakeup is live.
        case background
        case ended
        case unknown
    }

    public struct Tool: Sendable, Equatable, Codable {
        public var name: String
        /// The Bash command, or a one-line summary of the tool input.
        public var command: String?
        public var startedAt: Date?

        public init(name: String, command: String? = nil, startedAt: Date? = nil) {
            self.name = name
            self.command = command
            self.startedAt = startedAt
        }

        private enum CodingKeys: String, CodingKey {
            case name, command
            case startedAt = "started_at"
        }
    }

    /// Which evidence decided the kind. `process` means hooks were silent or stale
    /// and the pane's process tree showed a foreground command.
    public enum Source: String, Sendable, Codable {
        case hook, transcript, screen, process
    }

    public var kind: Kind
    public var tool: Tool?
    /// When this kind began; "for how long" is `now - since`.
    public var since: Date?
    public var source: Source

    public init(kind: Kind, tool: Tool? = nil, since: Date? = nil, source: Source) {
        self.kind = kind
        self.tool = tool
        self.since = since
        self.source = source
    }
}

/// Whether an agent can be interrupted and resumed (restart, update, hibernation)
/// without losing work. Advisory: each consumer decides what to do with it.
public enum ResumeSafety: String, Sendable, Codable, Comparable {
    /// Idle, awaiting input, or between tool calls.
    case safe
    /// A model request, subagents, background work or a read-only tool in flight;
    /// resuming and re-issuing handles it.
    case care
    /// A foreground command, an unanswered question or permission, or a draft.
    case risky

    public static func < (lhs: ResumeSafety, rhs: ResumeSafety) -> Bool {
        let order: [ResumeSafety] = [.safe, .care, .risky]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public struct ResumeSafetyAssessment: Sendable, Equatable, Codable {
    public enum Reason: String, Sendable, Codable {
        case idle
        case awaitingInput = "awaiting_input"
        case betweenToolCalls = "between_tool_calls"
        case thinking
        case readOnlyTool = "read_only_tool"
        case foregroundCommand = "foreground_command"
        case subagents
        case backgroundWork = "background_work"
        case openQuestion = "open_question"
        case pendingPermission = "pending_permission"
        case draft
        /// The process census was unavailable or incomplete, so a foreground
        /// command cannot be ruled out.
        case processUnknown = "process_unknown"
        case ended
        case unknown
    }

    public var safety: ResumeSafety
    public var reasons: [Reason]

    public init(safety: ResumeSafety, reasons: [Reason]) {
        self.safety = safety
        self.reasons = reasons
    }
}

/// The facts the app gathers about one agent pane. Every field is optional
/// evidence; the classifier never guesses past what it is given.
public struct AgentActivitySignals: Sendable, Equatable {
    public var ended = false
    public var pendingPermission = false
    public var pendingQuestion = false
    /// A PreToolUse with no matching PostToolUse yet.
    public var openTool: AgentActivity.Tool?
    /// Between UserPromptSubmit and Stop.
    public var turnActive = false
    /// The last hook in an active turn was a PostToolUse.
    public var lastToolFinished = false
    /// Stop fired with background tasks or scheduled wakeups still live.
    public var backgroundWork = false
    /// The turn ended waiting on a human (idle prompt notification).
    public var awaitingInput = false
    /// A live, non-background child in the agent's foreground process group,
    /// described by its argv. Holds even when hooks are stale.
    public var foregroundCommand: String?
    /// The process census failed or was partial, so ``foregroundCommand`` being
    /// nil proves nothing.
    public var foregroundCommandUnknown = false
    /// Whether the agent's prompt holds a half-typed draft; nil when unknown.
    public var hasDraft: Bool?
    /// When the latest observed transition happened.
    public var since: Date?
    /// Whether any lifecycle hook has ever reported for this pane.
    public var hasHookEvidence = true

    public init() {}
}

public enum AgentActivityClassifier {
    /// Tools that only read. A resume re-issues them without side effects.
    public static let readOnlyTools: Set<String> = [
        "Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "NotebookRead", "TodoRead",
    ]

    /// Subagent launchers: time inside them is subagent work, not a foreground tool.
    public static let subagentTools: Set<String> = ["Task", "Agent"]

    public static func classify(_ signals: AgentActivitySignals) -> (activity: AgentActivity, safety: ResumeSafetyAssessment) {
        let since = signals.since
        let (activity, safety, reason): (AgentActivity, ResumeSafety, ResumeSafetyAssessment.Reason) = {
            if signals.ended {
                return (AgentActivity(kind: .ended, since: since, source: .hook), .safe, .ended)
            }
            if signals.pendingPermission {
                return (AgentActivity(kind: .permission, tool: signals.openTool, since: since, source: .hook), .risky, .pendingPermission)
            }
            if signals.pendingQuestion {
                return (AgentActivity(kind: .question, since: since, source: .hook), .risky, .openQuestion)
            }
            if let tool = signals.openTool {
                if subagentTools.contains(tool.name) {
                    return (AgentActivity(kind: .subagents, tool: tool, since: tool.startedAt ?? since, source: .hook), .care, .subagents)
                }
                if readOnlyTools.contains(tool.name) {
                    return (AgentActivity(kind: .tool, tool: tool, since: tool.startedAt ?? since, source: .hook), .care, .readOnlyTool)
                }
                return (AgentActivity(kind: .tool, tool: tool, since: tool.startedAt ?? since, source: .hook), .risky, .foregroundCommand)
            }
            // Hooks can go stale; a live foreground child is a running command.
            if let command = signals.foregroundCommand {
                let tool = AgentActivity.Tool(name: "process", command: command)
                return (AgentActivity(kind: .tool, tool: tool, since: since, source: .process), .risky, .foregroundCommand)
            }
            if signals.turnActive {
                return (AgentActivity(kind: .thinking, since: since, source: .hook),
                        signals.lastToolFinished ? .safe : .care,
                        signals.lastToolFinished ? .betweenToolCalls : .thinking)
            }
            if signals.backgroundWork {
                return (AgentActivity(kind: .background, since: since, source: .hook), .care, .backgroundWork)
            }
            if !signals.hasHookEvidence {
                return (AgentActivity(kind: .unknown, since: since, source: .process), .care, .unknown)
            }
            if signals.awaitingInput {
                return (AgentActivity(kind: .awaitingInput, since: since, source: .hook), .safe, .awaitingInput)
            }
            return (AgentActivity(kind: .idle, since: since, source: .hook), .safe, .idle)
        }()
        var assessment = ResumeSafetyAssessment(safety: safety, reasons: [reason])
        // Without a census, a command may be running unseen: never call it safe.
        if signals.foregroundCommandUnknown, assessment.safety == .safe, activity.kind != .ended {
            assessment.safety = .care
            assessment.reasons.append(.processUnknown)
        }
        // A draft is unsaved human input: never safe to drop, whatever the agent does.
        if signals.hasDraft == true, activity.kind != .ended {
            assessment.safety = .risky
            assessment.reasons.append(.draft)
        }
        return (activity, assessment)
    }
}
