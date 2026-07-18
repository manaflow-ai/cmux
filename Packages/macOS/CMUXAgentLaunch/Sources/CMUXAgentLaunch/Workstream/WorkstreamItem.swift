import Foundation

/// The user's decision on a resolved actionable item.
public enum WorkstreamDecision: Codable, Sendable, Equatable {
    case permission(WorkstreamPermissionMode)
    /// `feedback` carries the user's "Tell Claude what to change" text
    /// when non-nil. When present the hook translates into a
    /// `{decision: block, reason: feedback}` response so Claude refines
    /// rather than proceeding.
    case exitPlan(WorkstreamExitPlanMode, feedback: String? = nil)
    case question(selections: [String])
}

/// Lifecycle state of a `WorkstreamItem`.
public enum WorkstreamStatus: Codable, Sendable, Equatable {
    /// Actionable item awaiting user input. Only valid for
    /// `.permissionRequest`, `.exitPlan`, `.question`.
    case pending
    /// Actionable item the user resolved with the given decision.
    case resolved(WorkstreamDecision, at: Date)
    /// Actionable item that timed out before the user acted.
    case expired(at: Date)
    /// Telemetry item (non-actionable). Always starts and stays here.
    case telemetry

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// A single feed entry. Workstream IDs group items that belong to the same
/// agent session (e.g. `claude-<sessionId>`, `opencode-<sessionId>`).
public struct WorkstreamItem: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let workstreamId: String
    public let source: WorkstreamSource
    public let kind: WorkstreamKind
    public let createdAt: Date
    public var updatedAt: Date
    public var cwd: String?
    public var title: String?
    public var status: WorkstreamStatus
    public var payload: WorkstreamPayload
    public var context: WorkstreamContext?
    /// PID of the agent process that emitted the event (hook's parent
    /// pid). When non-nil, pending items get expired automatically as
    /// soon as the agent process is gone — a crashed/killed `claude`
    /// or `codex` would otherwise leave orphaned actionable cards
    /// waiting forever. Only the agent PID; not the hook subprocess.
    public var ppid: Int?

    public init(
        id: UUID = UUID(),
        workstreamId: String,
        source: WorkstreamSource,
        kind: WorkstreamKind,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        cwd: String? = nil,
        title: String? = nil,
        status: WorkstreamStatus? = nil,
        payload: WorkstreamPayload,
        context: WorkstreamContext? = nil,
        ppid: Int? = nil
    ) {
        self.id = id
        self.workstreamId = workstreamId
        self.source = source
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.cwd = cwd
        self.title = title
        let resolvedStatus = status ?? (kind.isActionable ? .pending : .telemetry)
        self.status = kind.isActionable ? resolvedStatus : .telemetry
        self.payload = payload
        self.context = context?.isEmpty == true ? nil : context
        self.ppid = ppid
    }
}

extension WorkstreamItem {
    /// Returns a copy whose variable-sized fields have deterministic limits.
    /// This bounds both the in-memory ring and the pending-item disk snapshot.
    func retainedForFeed() -> WorkstreamItem {
        WorkstreamItem(
            id: id,
            workstreamId: workstreamId.feedPrefix(512),
            source: source,
            kind: kind,
            createdAt: createdAt,
            updatedAt: updatedAt,
            cwd: cwd?.feedPrefix(4_096),
            title: title?.feedPrefix(1_024),
            status: status.retainedForFeed(),
            payload: payload.retainedForFeed(),
            context: context?.retainedForFeed(),
            ppid: ppid
        )
    }
}

private extension WorkstreamStatus {
    func retainedForFeed() -> WorkstreamStatus {
        switch self {
        case .resolved(.question(let selections), let date):
            return .resolved(
                .question(selections: selections.prefix(20).map { $0.feedPrefix(1_024) }),
                at: date
            )
        case .resolved(.exitPlan(let mode, let feedback), let date):
            return .resolved(.exitPlan(mode, feedback: feedback?.feedPrefix(8_192)), at: date)
        default:
            return self
        }
    }
}

private extension WorkstreamPayload {
    func retainedForFeed() -> WorkstreamPayload {
        switch self {
        case .permissionRequest(let requestId, let toolName, let toolInputJSON, let pattern):
            return .permissionRequest(
                requestId: requestId.feedPrefix(512),
                toolName: toolName.feedPrefix(512),
                toolInputJSON: toolInputJSON.feedPrefix(32_768),
                pattern: pattern?.feedPrefix(4_096)
            )
        case .exitPlan(let requestId, let plan, let defaultMode):
            return .exitPlan(
                requestId: requestId.feedPrefix(512),
                plan: plan.feedPrefix(65_536),
                defaultMode: defaultMode
            )
        case .question(let requestId, let questions):
            return .question(
                requestId: requestId.feedPrefix(512),
                questions: questions.prefix(4).map { question in
                    WorkstreamQuestionPrompt(
                        id: question.id.feedPrefix(512),
                        header: question.header?.feedPrefix(1_024),
                        prompt: question.prompt.feedPrefix(8_192),
                        multiSelect: question.multiSelect,
                        options: question.options.prefix(12).map { option in
                            WorkstreamQuestionOption(
                                id: option.id.feedPrefix(512),
                                label: option.label.feedPrefix(1_024),
                                description: option.description?.feedPrefix(2_048)
                            )
                        }
                    )
                }
            )
        case .toolUse(let toolName, let toolInputJSON):
            return .toolUse(
                toolName: toolName.feedPrefix(512),
                toolInputJSON: toolInputJSON.feedPrefix(32_768)
            )
        case .toolResult(let toolName, let resultJSON, let isError):
            return .toolResult(
                toolName: toolName.feedPrefix(512),
                resultJSON: resultJSON.feedPrefix(32_768),
                isError: isError
            )
        case .userPrompt(let text):
            return .userPrompt(text: text.feedPrefix(16_384))
        case .assistantMessage(let text):
            return .assistantMessage(text: text.feedPrefix(16_384))
        case .stop(let reason):
            return .stop(reason: reason?.feedPrefix(4_096))
        case .todos(let todos):
            return .todos(todos.prefix(100).map { todo in
                WorkstreamTaskTodo(
                    id: todo.id.feedPrefix(512),
                    content: todo.content.feedPrefix(2_048),
                    state: todo.state
                )
            })
        case .sessionStart, .sessionEnd:
            return self
        }
    }
}

extension WorkstreamContext {
    func retainedForFeed() -> WorkstreamContext {
        WorkstreamContext(
            lastUserMessage: lastUserMessage?.feedPrefix(16_384),
            assistantPreamble: assistantPreamble?.feedPrefix(16_384),
            planSummary: planSummary?.feedPrefix(8_192),
            allowedPrompts: allowedPrompts.prefix(20).map { prompt in
                WorkstreamAllowedPrompt(
                    tool: prompt.tool.feedPrefix(512),
                    prompt: prompt.prompt.feedPrefix(2_048)
                )
            },
            toolSummary: toolSummary?.feedPrefix(8_192),
            permissionMode: permissionMode?.feedPrefix(256)
        )
    }
}

private extension String {
    func feedPrefix(_ maximumCharacters: Int) -> String {
        guard count > maximumCharacters else { return self }
        return String(prefix(maximumCharacters))
    }
}
