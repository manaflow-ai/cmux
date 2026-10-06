import Foundation

/// The exact inverse of one intent's last overlay apply, so the overlay
/// can be lifted before daemon events apply to the confirmed records and
/// put back after.
enum IntentUndo: Equatable {
    case moveTab(surface: SurfaceID, fromPane: PaneID, fromIndex: Int, toPane: PaneID)
    case tabName(surface: SurfaceID, name: String?)
    case tabPinned(surface: SurfaceID, pinned: Bool)
    case workspaceName(key: WorkspaceKey, name: String)
    /// The workspace's daemon-order index and group before the apply.
    case workspacePlace(key: WorkspaceKey, index: Int, group: WorkspaceGroupID?)
    case workspaceGroupCollapsed(WorkspaceGroupID, collapsed: Bool)
    case tabGroupCollapsed(TabGroupID, collapsed: Bool)
    /// The column's row heights before the apply.
    case rowHeights(column: ColumnID, heights: [RowHeightValue])
    /// The provisional tab a create intent inserted.
    case createdTab(surface: SurfaceID, pane: PaneID)
    /// The tab's record before a session bind.
    case tabSnapshot(surface: SurfaceID, previous: TabSnapshot)
}

struct PendingIntent {
    let transaction: ClientTransactionID
    let kind: Intent
    /// The intent settles once the store's applied sequence reaches this
    /// (nil until known). The one place a `request-settled` sequence plugs in.
    var settleSequence: UInt64?
    /// The reply came on a connection that ended before the store applied
    /// its events: the next snapshot (requested on the next connection,
    /// so ordered after the reply) holds its result.
    var settlesAtSnapshot = false
    /// Inverse of the overlay apply now in the records (nil when that apply
    /// changed nothing).
    var undo: IntentUndo?
    /// A create intent whose reply named the daemon's tab: once the records hold that surface,
    /// the provisional tab is no longer shown.
    var createdSurface: SurfaceID?
}

/// The ordered log of pending intents. Pure bookkeeping: the store applies
/// and lifts the overlay (`DaemonStore+Intents.swift`).
struct IntentLog {
    private(set) var entries: [PendingIntent] = []
    /// Recently settled transactions (bounded), so a late echo, reply or
    /// rejection for one never settles it again.
    private var settled: [ClientTransactionID] = []
    let settledLimit: Int

    init(settledLimit: Int = 256) {
        self.settledLimit = settledLimit
    }

    var isEmpty: Bool { entries.isEmpty }

    func contains(_ transaction: ClientTransactionID) -> Bool {
        entries.contains { $0.transaction == transaction }
    }

    func wasSettled(_ transaction: ClientTransactionID) -> Bool { settled.contains(transaction) }

    /// Appends a new intent. False when the transaction is already pending
    /// or already settled (an id is never reused).
    mutating func append(_ intent: Intent, transaction: ClientTransactionID) -> Bool {
        guard !contains(transaction), !wasSettled(transaction) else { return false }
        entries.append(PendingIntent(transaction: transaction, kind: intent))
        return true
    }

    /// Records the sequence that settles `transaction`; keeps the smaller
    /// of two (either bound is sound: every event up to it is applied).
    mutating func settle(_ transaction: ClientTransactionID, at sequence: UInt64) {
        guard let index = entries.firstIndex(where: { $0.transaction == transaction }) else { return }
        entries[index].settleSequence = min(entries[index].settleSequence ?? sequence, sequence)
    }

    /// The reply came but no sequence bounds it: settle at the next snapshot.
    mutating func settleAtSnapshot(_ transaction: ClientTransactionID) {
        guard let index = entries.firstIndex(where: { $0.transaction == transaction }) else { return }
        entries[index].settlesAtSnapshot = true
    }

    /// Removes and returns the intent for `transaction`, recording it as settled.
    mutating func remove(_ transaction: ClientTransactionID) -> PendingIntent? {
        guard let index = entries.firstIndex(where: { $0.transaction == transaction }) else { return nil }
        noteSettled(transaction)
        return entries.remove(at: index)
    }

    func hasDue(appliedSequence: UInt64) -> Bool {
        entries.contains { Self.isDue($0, appliedSequence: appliedSequence, snapshot: false) }
    }

    /// Removes the intents whose settle sequence the store reached (and,
    /// after a snapshot, those waiting for one).
    mutating func removeDue(appliedSequence: UInt64, snapshot: Bool = false) -> [PendingIntent] {
        let due = entries.filter { Self.isDue($0, appliedSequence: appliedSequence, snapshot: snapshot) }
        guard !due.isEmpty else { return [] }
        entries.removeAll { Self.isDue($0, appliedSequence: appliedSequence, snapshot: snapshot) }
        for intent in due { noteSettled(intent.transaction) }
        return due
    }

    /// A new connection numbers its events from its own serial, so a settle
    /// sequence from the previous one no longer compares: an intent whose
    /// reply came settles with the new connection's first snapshot.
    mutating func connectionReplaced() {
        for index in entries.indices where entries[index].settleSequence != nil {
            entries[index].settleSequence = nil
            entries[index].settlesAtSnapshot = true
        }
    }

    private static func isDue(_ intent: PendingIntent, appliedSequence: UInt64, snapshot: Bool) -> Bool {
        if snapshot, intent.settlesAtSnapshot { return true }
        return intent.settleSequence.map { appliedSequence >= $0 } ?? false
    }

    mutating func noteCreated(_ transaction: ClientTransactionID, surface: SurfaceID) {
        guard let index = entries.firstIndex(where: { $0.transaction == transaction }) else { return }
        entries[index].createdSurface = surface
    }

    mutating func setUndo(_ undo: IntentUndo?, at index: Int) {
        entries[index].undo = undo
    }

    private mutating func noteSettled(_ transaction: ClientTransactionID) {
        settled.append(transaction)
        if settled.count > settledLimit { settled.removeFirst(settled.count - settledLimit) }
    }
}
