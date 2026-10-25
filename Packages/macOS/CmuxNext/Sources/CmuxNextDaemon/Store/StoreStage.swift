import CmuxNextWakeups
import Foundation

/// A script batch's stage on one store (CLAUDE.md "Go past Chrome where cmux is scripted": a burst
/// of scripted changes coalesces to one model update). While it is open, what the batch changes in
/// the workspaces it touches is held back, and shows in one pass when it commits:
///
/// - Its own intents (those made under one of its ``DaemonCommandScope``s) that change a tab or a
///   workspace in place (a rename, a pin, a move, a reorder) are logged but not shown.
/// - Daemon events of the workspaces those intents touch wait in the stage, in order, and so do
///   events that echo one of its transactions or touch a workspace already held. The applied
///   sequence stops below the first one it holds, so nothing waits on a held change as if applied.
///
/// Nothing else waits: events of every other workspace and window apply at once, and so do the
/// person's own intents, also in a touched workspace (input goes before automation). Creates,
/// splits and closes are not held: their stand-ins show in their op's own turn.
///
/// The stage commits on ``commit()`` (the batch's last slice ran or it ended early), at its
/// deadline, before a snapshot applies, and when the connection changes (a lifecycle event).
/// One per store at a time: a second batch while one is open joins it, and the stage commits
/// when the last of them did.
@MainActor
public final class StoreStage {
    private weak var store: DaemonStore?
    /// The scopes whose intents are the batch's (one per joined batch).
    private var scopes: Set<ObjectIdentifier> = []
    private var participants = 0
    /// Workspaces the stage holds, by daemon handle.
    private(set) var workspaces: Set<WorkspaceHandle> = []
    /// Transactions of its held intents.
    private(set) var transactions: Set<ClientTransactionID> = []
    /// Daemon events it holds, in arrival order.
    private(set) var events: [DaemonEventEnvelope] = []
    /// The highest sequence the store applied (or capped) while staged: it reaches it at commit.
    private var highestSeen: UInt64 = 0
    /// The first held event's sequence: the store's applied sequence stays below it.
    private var firstHeld: UInt64?
    /// The stage's one deadline (a batch whose commit never comes does not hold the store).
    private var deadline: DemandTimer?
    /// When the stage commits by itself.
    private var deadlineAt: ContinuousClock.Instant?
    /// The stage holds a change of the workspace list's order (a workspace move, add or close, or a
    /// move or group intent): every later order event waits too, since list indexes do not commute.
    private var holdsList = false
    public private(set) var isOpen = true

    init(store: DaemonStore) {
        self.store = store
    }

    /// Joins one batch: its scope's intents are held from now on. The stage commits by itself at
    /// `deadline` (a batch whose commit never comes does not hold the store).
    func join(scope: DaemonCommandScope?, until deadline: ContinuousClock.Instant, clock: any Clock<Duration>) {
        participants += 1
        if let scope { scopes.insert(ObjectIdentifier(scope)) }
        // The earliest deadline holds: a batch that joins later never keeps the stage open longer.
        guard deadlineAt.map({ deadline < $0 }) ?? true else { return }
        deadlineAt = deadline
        let timer = self.deadline ?? DemandTimer(owner: "StoreStage.deadline", clock: clock)
        self.deadline = timer
        timer.schedule(after: max(deadline - .now, .zero)) { @MainActor [weak self] in self?.commit(all: true) }
    }

    /// Ends one batch's part; the stage commits when every joined batch ended.
    public func commit() {
        commit(all: false)
    }

    func commit(all: Bool) {
        guard isOpen else { return }
        participants = all ? 0 : max(0, participants - 1)
        guard participants == 0 else { return }
        isOpen = false
        deadline?.cancel()
        deadline = nil
        guard let store, store.stage === self else { return }
        store.stage = nil
        let held = events
        events = []
        store.intentLog.releaseHeld()
        // One pass: the held events onto the confirmed records, then every pending intent (the held
        // ones among them, in log order) back on top.
        let followup = held.isEmpty ? .none : store.apply(batch: held)
        if held.isEmpty { store.withOverlayLifted(writer: "stage commit") {} }
        store.advanceAppliedSequence(to: highestSeen)
        if followup == .resync || store.needsResync {
            store.resync()
        } else if followup == .personal {
            store.refetchPersonal()
        }
    }

    // MARK: Store hooks

    /// Whether `intent` is this stage's to hold: made under one of its scopes, of a kind that
    /// changes a tab or a workspace in place, in workspaces the store knows. Records them.
    func holds(_ intent: Intent, transaction: ClientTransactionID, in store: DaemonStore) -> Bool {
        guard isOpen, let scope = DaemonCommandScope.current, scopes.contains(ObjectIdentifier(scope)),
              let reached = store.stageWorkspaces(of: intent), !reached.isEmpty else { return false }
        workspaces.formUnion(reached)
        transactions.insert(transaction)
        if Self.changesListOrder(intent) { holdsList = true }
        return true
    }

    /// The events of `batch` the store applies now; the rest wait in the stage. A lifecycle event
    /// (the connection changed, the inbox overflowed) commits the stage first, and all apply.
    func passing(_ batch: [DaemonEventEnvelope], in store: DaemonStore) -> [DaemonEventEnvelope] {
        guard isOpen else { return batch }
        if batch.contains(where: { store.stageReach(of: $0.event) == nil }) {
            commit(all: true)
            return batch
        }
        var now: [DaemonEventEnvelope] = []
        for envelope in batch {
            let reach = store.stageReach(of: envelope.event) ?? []
            let echoesHeld = envelope.event.clientTransactionID.map(transactions.contains) ?? false
            let listOrder = Self.changesListOrder(envelope.event)
            guard echoesHeld || !reach.isDisjoint(with: workspaces) || (listOrder && holdsList) else {
                now.append(envelope)
                continue
            }
            workspaces.formUnion(reach)
            if listOrder { holdsList = true }
            events.append(envelope)
            firstHeld = firstHeld.map { min($0, envelope.sequence) } ?? envelope.sequence
        }
        return now
    }

    /// Whether a waiter for `sequence` (or for `transaction`'s echo) needs an event the stage holds:
    /// the store then commits the stage first, so a read-your-writes wait never waits on a script.
    func holds(through sequence: UInt64?, echo transaction: ClientTransactionID? = nil) -> Bool {
        guard isOpen else { return false }
        if let sequence, let firstHeld, sequence >= firstHeld { return true }
        guard let transaction else { return false }
        return events.contains { $0.event.clientTransactionID == transaction }
    }

    /// Whether `intent` changes the workspace list's order (a move, a group change).
    static func changesListOrder(_ intent: Intent) -> Bool {
        switch intent {
        case .moveWorkspace, .placeWorkspace, .setWorkspaceGroup: true
        default: false
        }
    }

    /// Whether `event` changes the workspace list's order (it carries a list index).
    static func changesListOrder(_ event: DaemonEvent) -> Bool {
        switch event {
        case .workspaceAdded, .workspaceClosed, .workspaceMoved: true
        default: false
        }
    }

    /// `sequence`, but below the first event the stage holds.
    func cappedSequence(_ sequence: UInt64) -> UInt64 {
        highestSeen = max(highestSeen, sequence)
        guard isOpen, let firstHeld else { return sequence }
        return min(sequence, firstHeld &- 1)
    }
}
