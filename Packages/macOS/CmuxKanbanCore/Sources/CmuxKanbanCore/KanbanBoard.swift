public import Foundation

/// The persisted Kanban board for one workspace.
///
/// Owns the ordered list of ``KanbanCard`` plus board-level dispatch policy:
/// the WIP limit (max cards in flight under autonomous "ripping"), whether
/// ripping is enabled, and an optional `testCommand` used as the gate that
/// moves a card from `testing` to `done`.
///
/// Mutations are expressed as value-returning members (no free functions, no
/// shared mutable state) so the board stays trivially testable.
public struct KanbanBoard: Codable, Sendable, Equatable {
    /// Persisted schema version, bumped when the on-disk shape changes.
    public var schemaVersion: Int
    public var workspaceId: UUID
    /// Maximum number of cards allowed in WIP-occupying columns at once when
    /// ripping is enabled.
    public var wipLimit: Int
    /// Whether autonomous dispatch ("ripping") is enabled for this board.
    public var ripping: Bool
    /// Optional shell command run in a card's worktree as the `testing → done`
    /// gate. `nil` skips the testing gate (cards go straight to `done`).
    public var testCommand: String?
    public var defaultBackend: KanbanBackendKind
    /// Raw provider identifier (e.g. `"claude"`) used for new `cmux` cards; see
    /// ``KanbanCard/agentProvider``.
    public var defaultProvider: String
    public var cards: [KanbanCard]
    public var updatedAt: Date

    /// The current schema version emitted by this build.
    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = KanbanBoard.currentSchemaVersion,
        workspaceId: UUID,
        wipLimit: Int = 2,
        ripping: Bool = false,
        testCommand: String? = nil,
        defaultBackend: KanbanBackendKind = .cmux,
        defaultProvider: String = "claude",
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
    public static func empty(workspaceId: UUID, now: Date) -> KanbanBoard {
        KanbanBoard(workspaceId: workspaceId, updatedAt: now)
    }

    /// Cards currently in the given column, preserving insertion order.
    public func cards(in column: KanbanColumn) -> [KanbanCard] {
        cards.filter { $0.column == column }
    }

    /// Number of cards occupying a WIP slot (in `building` or `testing`).
    public var wipInUse: Int {
        cards.reduce(into: 0) { count, card in
            if card.column.occupiesWipSlot { count += 1 }
        }
    }

    /// The card with the given `id`, if present.
    public func card(id: UUID) -> KanbanCard? {
        cards.first { $0.id == id }
    }

    /// Returns a copy with `card` inserted (if new) or replaced (if its `id`
    /// already exists), stamping `updatedAt` on both the card and the board.
    public func upserting(_ card: KanbanCard, now: Date) -> KanbanBoard {
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
    public func movingCard(id: UUID, to column: KanbanColumn, now: Date) -> KanbanBoard {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        copy.cards[index].column = column
        copy.cards[index].updatedAt = now
        copy.updatedAt = now
        return copy
    }

    /// Returns a copy with the card at `id` removed, stamping `updatedAt`.
    public func removingCard(id: UUID, now: Date) -> KanbanBoard {
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
    public func reconcilingOrphansAfterRelaunch(now: Date) -> KanbanBoard {
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
