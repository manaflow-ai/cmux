import Foundation

/// The exact inverse of one intent's last overlay apply, so the overlay
/// can be lifted before daemon events apply to the confirmed records and
/// put back after.
enum IntentUndo: Equatable {
    case moveTab(surface: SurfaceID, fromPane: PaneID, fromIndex: Int, toPane: PaneID)
    case tabName(surface: SurfaceID, name: String?)
    case tabPinned(surface: SurfaceID, pinned: Bool)
    case paneName(pane: PaneID, name: String?)
    case screenName(screen: ScreenID, name: String?)
    case screenColor(screen: ScreenID, color: String?)
    case screenIcon(screen: ScreenID, icon: String?)
    case screenPinned(screen: ScreenID, pinned: Bool)
    case workspaceName(key: WorkspaceKey, name: String)
    case workspaceColor(key: WorkspaceKey, color: String?)
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
    /// The screen's split tree and columns before a provisional split, and the provisional pane
    /// (nil when the split placed the daemon's pane, which the records already list).
    case splitPane(screen: ScreenID, layout: LayoutNode, columns: [ColumnSnapshot], pane: PaneID?)
    /// The daemon's tab or pane of a creation the person closed first (``CancelledCreation``).
    case hiddenTab(HiddenTab)
    case hiddenPane(HiddenPane)
    /// The daemon tabs a close intent took out of the visible records, in removal order.
    case closedTabs([HiddenTab])
    /// A create's guessed daemon tab hidden (``ProvisionalTab/matched(_:in:)``) and its
    /// provisional tab shown, until the daemon names the tab's create.
    indirect case guessedTab(hidden: HiddenTab, provisional: IntentUndo?)
    /// The provisional screen shown in workspace `key`, and whether the workspace itself was the
    /// provisional one (inserted) rather than the daemon's.
    case createdWorkspace(key: WorkspaceKey, inserted: Bool)
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
    /// `createdSurface` came from the daemon naming this transaction (its echo or reply), not
    /// from ``ProvisionalTab/matched(_:in:)``'s guess. A guessed tab is only hidden (the
    /// provisional tab shows meanwhile); only a confirmed one replaces it or is ever closed.
    var createdConfirmed = false
    /// Due, but what it shows has not reached the daemon's records yet (a split's pane, cx-ry0y):
    /// it leaves the log once they hold it, or with the next snapshot.
    var awaitsRecords = false
    /// A split's daemon pane reached the records (its `pane-added`): once it
    /// leaves them, the split has nothing left to place (``ProvisionalSplit/paneGone(_:in:)``).
    var daemonPaneSeen = false
    /// The person closed what it creates before the daemon made it (``CancelledCreation``): it
    /// shows nothing, hides the daemon's tab or pane, and leaves once the records drop it.
    var closeWhenCreated = false
    /// The daemon's surface was handed to the close (``DaemonCreations/onClose(_:)``).
    var closeRequested = false
    /// The surface the creation's reply named (a split's; a create's is `createdSurface`).
    var replySurface: SurfaceID?
    /// Closes of a cancelled creation's daemon surface sent so far (a timed-out close is sent again).
    var closeAttempts = 0
    /// A script batch's intent held back by its ``StoreStage``: in the log (ordered with the rest)
    /// but not shown, and never due, until the stage commits.
    var held = false
}

/// The ordered log of pending intents. Pure bookkeeping: the store applies
/// and lifts the overlay (`DaemonStore+Intents.swift`).
struct IntentLog {
    private(set) var entries: [PendingIntent] = []
    /// The models Cmd-N's pending creates show (``DaemonStore/provisionalWorkspaces``).
    var workspaceModels = ProvisionalWorkspaceModels()
    /// Closes the daemon's surface of a creation the person closed first (``DaemonCreations/onClose(_:)``).
    var closeCancelled: ((ClientTransactionID, SurfaceID) -> Void)?
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
    mutating func append(_ intent: Intent, transaction: ClientTransactionID, held: Bool = false) -> Bool {
        guard !contains(transaction), !wasSettled(transaction) else { return false }
        var entry = PendingIntent(transaction: transaction, kind: intent)
        entry.held = held
        entries.append(entry)
        return true
    }

    /// Whether any intent is held by a stage.
    var hasHeld: Bool { entries.contains(where: \.held) }

    /// Shows the held intents with the rest (their stage committed): the next overlay restore
    /// applies them in log order.
    mutating func releaseHeld() {
        entries = entries.map { entry in
            var entry = entry
            entry.held = false
            return entry
        }
    }

    /// Records the sequence that settles `transaction`; keeps the smaller
    /// of two (either bound is sound: every event up to it is applied).
    mutating func settle(_ transaction: ClientTransactionID, at sequence: UInt64) {
        entries.modifyFirst(where: { $0.transaction == transaction }) { entry in
            entry.settleSequence = min(entry.settleSequence ?? sequence, sequence)
        }
    }

    /// The reply came but no sequence bounds it: settle at the next snapshot.
    mutating func settleAtSnapshot(_ transaction: ClientTransactionID) {
        entries.modifyFirst(where: { $0.transaction == transaction }) { $0.settlesAtSnapshot = true }
    }

    /// Removes and returns the intent for `transaction`, recording it as settled.
    mutating func remove(_ transaction: ClientTransactionID) -> PendingIntent? {
        guard let index = entries.firstIndex(where: { $0.transaction == transaction }) else { return nil }
        noteSettled(transaction)
        return entries.remove(at: index)
    }

    /// Whether a settlement would remove anything now. An intent awaiting the records leaves on
    /// the apply that brings them, never on a settlement by itself.
    func hasDue(appliedSequence: UInt64) -> Bool {
        entries.contains { !$0.awaitsRecords && Self.isDue($0, appliedSequence: appliedSequence, snapshot: false) }
    }

    /// Removes the intents whose settle sequence the store reached (and,
    /// after a snapshot, those waiting for one). A due intent whose result
    /// the records do not show yet (`awaiting`) stays until they do, so its
    /// undo and the daemon's result land in one apply; a snapshot removes it
    /// regardless, as it holds everything the daemon did.
    mutating func removeDue(appliedSequence: UInt64, snapshot: Bool = false,
                            awaiting: (PendingIntent) -> Bool = { _ in false }) -> [PendingIntent] {
        var due: [PendingIntent] = []
        var kept: [PendingIntent] = []
        for var entry in entries {
            guard entry.awaitsRecords || Self.isDue(entry, appliedSequence: appliedSequence, snapshot: snapshot) else {
                kept.append(entry)
                continue
            }
            // A cancelled creation stays while the records hold what it made, snapshot or not.
            if !snapshot || entry.closeWhenCreated, awaiting(entry) {
                entry.awaitsRecords = true
                kept.append(entry)
            } else {
                due.append(entry)
            }
        }
        entries = kept
        for intent in due { noteSettled(intent.transaction) }
        return due
    }

    /// A new connection numbers its events from its own serial, so a settle
    /// sequence from the previous one no longer compares: an intent whose
    /// reply came settles with the new connection's first snapshot.
    mutating func connectionReplaced() {
        entries = entries.map { entry in
            var entry = entry
            if entry.settleSequence != nil {
                entry.settleSequence = nil
                entry.settlesAtSnapshot = true
            }
            return entry
        }
    }

    private static func isDue(_ intent: PendingIntent, appliedSequence: UInt64, snapshot: Bool) -> Bool {
        // A held intent never showed: it leaves only after its stage released it.
        if intent.held { return false }
        if snapshot, intent.settlesAtSnapshot { return true }
        return intent.settleSequence.map { appliedSequence >= $0 } ?? false
    }

    /// Settled, but what it shows has not reached the records yet: it leaves the log on the
    /// apply that brings them, or with the next snapshot.
    mutating func awaitRecords(_ transaction: ClientTransactionID) {
        entries.modifyFirst(where: { $0.transaction == transaction }) { $0.awaitsRecords = true }
    }

    /// Recently cancelled creations (bounded), still known after their intent left the log, so a
    /// late reply never selects or focuses what the person closed.
    private var cancelled: [ClientTransactionID] = []

    func wasCancelled(_ transaction: ClientTransactionID) -> Bool { cancelled.contains(transaction) }

    /// False when `transaction` is not pending.
    mutating func markCloseWhenCreated(_ transaction: ClientTransactionID) -> Bool {
        guard entries.modifyFirst(where: { $0.transaction == transaction }, { $0.closeWhenCreated = true }) else { return false }
        cancelled.append(transaction)
        if cancelled.count > settledLimit { cancelled.removeFirst(cancelled.count - settledLimit) }
        return true
    }

    mutating func noteCloseRequested(_ transaction: ClientTransactionID) {
        entries.modifyFirst(where: { $0.transaction == transaction }) {
            $0.closeRequested = true
            $0.closeAttempts += 1
        }
    }

    /// The close of a cancelled creation's surface timed out: it may be sent again (at most
    /// `limit` sends in all). False when it is not pending or is out of attempts.
    mutating func allowCloseRetry(_ transaction: ClientTransactionID, limit: Int) -> Bool {
        entries.modifyFirst(where: { $0.transaction == transaction && $0.closeAttempts < limit }) { $0.closeRequested = false }
    }

    /// The daemon reported the pane under public id `paneID`: the split that mints it saw its pane.
    mutating func noteDaemonPane(_ paneID: String) {
        entries.modifyFirst(where: { entry in
            guard case .splitPane(_, _, _, let provisional) = entry.kind else { return false }
            return provisional.paneID == paneID
        }) { $0.daemonPaneSeen = true }
    }

    mutating func noteReplySurface(_ transaction: ClientTransactionID, surface: SurfaceID) {
        entries.modifyFirst(where: { $0.transaction == transaction }) { $0.replySurface = surface }
    }

    /// `confirmed`: the daemon named `transaction` with `surface`; a guess elsewhere that named
    /// the same surface is dropped (that create's own echo or reply will name its tab).
    mutating func noteCreated(_ transaction: ClientTransactionID, surface: SurfaceID, confirmed: Bool = true) {
        entries.modifyFirst(where: { $0.transaction == transaction }) {
            $0.createdSurface = surface
            if confirmed { $0.createdConfirmed = true }
        }
        guard confirmed else { return }
        entries = entries.map { entry in
            guard entry.transaction != transaction, entry.createdSurface == surface, !entry.createdConfirmed else { return entry }
            var entry = entry
            entry.createdSurface = nil
            return entry
        }
    }

    /// False (nothing set) when `index` is not in the log.
    @discardableResult
    mutating func setUndo(_ undo: IntentUndo?, at index: Int) -> Bool {
        entries.modify(checked: index) { $0.undo = undo }
    }

    private mutating func noteSettled(_ transaction: ClientTransactionID) {
        settled.append(transaction)
        if settled.count > settledLimit { settled.removeFirst(settled.count - settledLimit) }
    }
}
