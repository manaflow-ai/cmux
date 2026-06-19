import Foundation

/// A column in the Kanban board's task pipeline.
///
/// Models the autonomous-board lifecycle (inspired by the CNVS "Forge"): tasks
/// move `backlog → ready → building → testing → done`, with `blocked` and
/// `failed` as off-pipeline exception states that wait for human intervention
/// or a retry.
///
/// Decoding is tolerant: an unknown raw value (e.g. a column added by a newer
/// build, then read back by an older one) falls back to ``backlog`` rather than
/// throwing, so a persisted board never fails to load over a schema bump.
enum KanbanColumn: String, CaseIterable, Codable, Sendable {
    case backlog
    case ready
    case building
    case testing
    case done
    case blocked
    case failed

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanColumn(rawValue: raw) ?? .backlog
    }

    /// Whether a card in this column is actively occupying a dispatch slot
    /// (counts against the board's WIP limit).
    var occupiesWipSlot: Bool {
        switch self {
        case .building, .testing:
            return true
        case .backlog, .ready, .done, .blocked, .failed:
            return false
        }
    }

    /// Whether this is a terminal column (no further automatic transition).
    var isTerminal: Bool {
        switch self {
        case .done, .failed:
            return true
        case .backlog, .ready, .building, .testing, .blocked:
            return false
        }
    }
}

/// The dispatch backend that executes a card's task.
///
/// `cmux` runs the task as a native agent session in-process (the default);
/// `cnvs` proxies to a running CNVS "Forge" via its CLI/MCP; `hermes` posts to
/// a Hermes agent gateway over loopback HTTP. Decoding is tolerant: an unknown
/// raw value falls back to ``cmux``.
enum KanbanBackendKind: String, CaseIterable, Codable, Sendable {
    case cmux
    case cnvs
    case hermes

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanBackendKind(rawValue: raw) ?? .cmux
    }
}

/// A single task on the Kanban board.
///
/// A card is the unit of work: a title plus an optional `detail` spec that
/// becomes the prompt sent to the chosen agent. Runtime fields (`sessionId`,
/// `worktreePath`, `lastExitStatus`) are populated once the card is dispatched
/// and are not valid across an app relaunch — see
/// ``KanbanBoard/reconcilingOrphansAfterRelaunch()``.
struct KanbanCard: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    /// Short human-facing title shown on the card.
    var title: String
    /// Full spec / prompt sent to the agent when the card is dispatched.
    var detail: String
    var column: KanbanColumn
    /// Which dispatch backend runs this card.
    var backendKind: KanbanBackendKind
    /// The native provider used when ``backendKind`` is ``KanbanBackendKind/cmux``.
    /// `nil` for external backends, which carry their own agent identity in
    /// ``agentLabel``.
    var agentProvider: AgentSessionProviderID?
    /// Free-form agent identifier for external backends (e.g. a CNVS agent name
    /// or a Hermes endpoint label).
    var agentLabel: String?
    /// Backend session/run identifier once dispatched; cleared when the run ends
    /// or the app relaunches.
    var sessionId: String?
    /// Absolute path of the isolated git worktree provisioned for this card.
    var worktreePath: String?
    /// Branch name of the card's worktree.
    var branchName: String?
    /// Path to this card's append-only log file (`kanban/logs/<id>.log`).
    var logsRef: String?
    /// Exit status of the last completed run, if any.
    var lastExitStatus: Int32?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        column: KanbanColumn = .backlog,
        backendKind: KanbanBackendKind = .cmux,
        agentProvider: AgentSessionProviderID? = nil,
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

/// The persisted Kanban board for one workspace.
///
/// Owns the ordered list of ``KanbanCard`` plus board-level dispatch policy:
/// the WIP limit (max cards in flight under autonomous "ripping"), whether
/// ripping is enabled, and an optional `testCommand` used as the gate that
/// moves a card from `testing` to `done`.
///
/// Mutations are expressed as value-returning members (no free functions, no
/// shared mutable state) so the board stays trivially testable.
struct KanbanBoard: Codable, Sendable, Equatable {
    /// Persisted schema version, bumped when the on-disk shape changes.
    var schemaVersion: Int
    var workspaceId: UUID
    /// Maximum number of cards allowed in WIP-occupying columns at once when
    /// ripping is enabled.
    var wipLimit: Int
    /// Whether autonomous dispatch ("ripping") is enabled for this board.
    var ripping: Bool
    /// Optional shell command run in a card's worktree as the `testing → done`
    /// gate. `nil` skips the testing gate (cards go straight to `done`).
    var testCommand: String?
    var defaultBackend: KanbanBackendKind
    var defaultProvider: AgentSessionProviderID
    var cards: [KanbanCard]
    var updatedAt: Date

    /// The current schema version emitted by this build.
    static let currentSchemaVersion = 1

    init(
        schemaVersion: Int = KanbanBoard.currentSchemaVersion,
        workspaceId: UUID,
        wipLimit: Int = 2,
        ripping: Bool = false,
        testCommand: String? = nil,
        defaultBackend: KanbanBackendKind = .cmux,
        defaultProvider: AgentSessionProviderID = .claude,
        cards: [KanbanCard] = [],
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.workspaceId = workspaceId
        self.wipLimit = wipLimit
        self.ripping = ripping
        self.testCommand = testCommand
        self.defaultBackend = defaultBackend
        self.defaultProvider = defaultProvider
        self.cards = cards
        self.updatedAt = updatedAt
    }

    /// An empty board for a workspace, using default policy.
    static func empty(workspaceId: UUID, now: Date) -> KanbanBoard {
        KanbanBoard(workspaceId: workspaceId, updatedAt: now)
    }

    /// Cards currently in the given column, preserving insertion order.
    func cards(in column: KanbanColumn) -> [KanbanCard] {
        cards.filter { $0.column == column }
    }

    /// Number of cards occupying a WIP slot (in `building` or `testing`).
    var wipInUse: Int {
        cards.reduce(into: 0) { count, card in
            if card.column.occupiesWipSlot { count += 1 }
        }
    }

    /// Returns a copy with `card` inserted (if new) or replaced (if its `id`
    /// already exists), stamping `updatedAt` on both the card and the board.
    func upserting(_ card: KanbanCard, now: Date) -> KanbanBoard {
        var copy = self
        var stamped = card
        stamped.updatedAt = now
        if let index = copy.cards.firstIndex(where: { $0.id == card.id }) {
            copy.cards[index] = stamped
        } else {
            copy.cards.append(stamped)
        }
        copy.updatedAt = now
        return copy
    }

    /// Returns a copy with the card at `id` moved to `column` (no-op if the
    /// card is absent), stamping timestamps.
    func movingCard(id: UUID, to column: KanbanColumn, now: Date) -> KanbanBoard {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        copy.cards[index].column = column
        copy.cards[index].updatedAt = now
        copy.updatedAt = now
        return copy
    }

    /// Returns a copy with the card at `id` removed, stamping `updatedAt`.
    func removingCard(id: UUID, now: Date) -> KanbanBoard {
        guard cards.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.cards.removeAll { $0.id == id }
        copy.updatedAt = now
        return copy
    }

    /// Returns a copy with in-flight cards reconciled after an app relaunch.
    ///
    /// Native agent processes do not survive a relaunch, so any card left in a
    /// WIP-occupying column (`building`/`testing`) references a dead session.
    /// Such cards are re-queued to `ready` when ripping is enabled (so the
    /// engine can pick them up again) or marked `failed` otherwise. Their stale
    /// `sessionId` is cleared either way.
    func reconcilingOrphansAfterRelaunch(now: Date) -> KanbanBoard {
        var copy = self
        var changed = false
        for index in copy.cards.indices where copy.cards[index].column.occupiesWipSlot {
            copy.cards[index].column = ripping ? .ready : .failed
            copy.cards[index].sessionId = nil
            copy.cards[index].updatedAt = now
            changed = true
        }
        if changed { copy.updatedAt = now }
        return copy
    }
}
