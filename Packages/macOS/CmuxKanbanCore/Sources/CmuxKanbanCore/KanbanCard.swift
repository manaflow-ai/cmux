public import Foundation

/// A single task on the Kanban board.
///
/// A card is the unit of work: a title plus an optional `detail` spec that
/// becomes the prompt sent to the chosen agent. Runtime fields (`sessionId`,
/// `worktreePath`, `lastExitStatus`) are populated once the card is dispatched
/// and are not valid across an app relaunch — see
/// ``KanbanBoard/reconcilingOrphansAfterRelaunch(now:)``.
public struct KanbanCard: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// Short human-facing title shown on the card.
    public var title: String
    /// Full spec / prompt sent to the agent when the card is dispatched.
    public var detail: String
    public var column: KanbanColumn
    /// Which dispatch backend runs this card.
    public var backendKind: KanbanBackendKind
    /// The native provider identifier used when ``backendKind`` is
    /// ``KanbanBackendKind/cmux`` (the raw value of the app's agent provider,
    /// e.g. `"claude"`). Carried as a plain string here so the core stays
    /// decoupled from the app's provider taxonomy; the app validates and maps it
    /// back into its concrete provider type at the dispatch boundary. `nil` for
    /// external backends, which carry their own agent identity in ``agentLabel``.
    public var agentProvider: String?
    /// Free-form agent identifier for external backends (e.g. a CNVS agent name
    /// or a Hermes endpoint label).
    public var agentLabel: String?
    /// Backend session/run identifier once dispatched; cleared when the run ends
    /// or the app relaunches.
    public var sessionId: String?
    /// Absolute path of the isolated git worktree provisioned for this card.
    public var worktreePath: String?
    /// Branch name of the card's worktree.
    public var branchName: String?
    /// Path to this card's append-only log file (`kanban/logs/<id>.log`).
    public var logsRef: String?
    /// Exit status of the last completed run, if any.
    public var lastExitStatus: Int32?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        column: KanbanColumn = .backlog,
        backendKind: KanbanBackendKind = .cmux,
        agentProvider: String? = nil,
        agentLabel: String? = nil,
        sessionId: String? = nil,
        worktreePath: String? = nil,
        branchName: String? = nil,
        logsRef: String? = nil,
        lastExitStatus: Int32? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.column = column
        self.backendKind = backendKind
        self.agentProvider = agentProvider
        self.agentLabel = agentLabel
        self.sessionId = sessionId
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.logsRef = logsRef
        self.lastExitStatus = lastExitStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
