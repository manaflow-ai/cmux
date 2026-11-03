import CmuxNextWakeups
import Foundation

/// A script batch's stage on one store (CLAUDE.md "Go past Chrome where cmux is scripted": a burst
/// of scripted changes coalesces to one model update). While it is open, what the batch changes in
/// the workspaces it touches is held back, and shows in one pass when it commits:
///
/// - Its own intents (those made under one of its ``DaemonCommandScope``s) that change a tab or a
///   workspace in place (a rename, a pin, a move, a reorder) are logged but not shown.
/// - Daemon events of the workspaces those intents touch wait in the stage, in order, and so do
///   events that echo one of its transactions, touch a workspace already held, name a tab or a
///   screen a held event adds, or carry a workspace revision after a held one. The applied sequence
///   stops below the first one it holds, so nothing waits on a held change as if applied.
///
/// Nothing else waits: events of every other workspace and window apply at once, and so do the
/// person's own intents, also in a touched workspace (input goes before automation). Creates,
/// splits and closes are not held: their stand-ins show in their op's own turn. A read-your-writes
/// wait never waits on the stage: an event it needs commits the stage first.
///
/// The stage commits when every joined batch ended (``StoreStageBatch/commit()``), at its deadline,
/// before a snapshot applies and on a lifecycle event (connected, disconnected, shutdown, overflow);
/// the end of its connection's run and a new connection discard it (the next snapshot is the truth).
/// One per store at a time: a second batch while one is open joins it.
@MainActor
public final class StoreStage {
    /// What the stage holds back, kept as one value so a pass can be undone before a commit.
    private struct Hold {
        /// Workspaces the stage holds, by daemon handle.
        var workspaces: Set<WorkspaceHandle> = []
        /// Transactions of its held intents.
        var transactions: Set<ClientTransactionID> = []
        /// Surfaces and screens a held event adds: a later event that names one waits too (it
        /// would find no record before the add applies).
        var surfaces: Set<SurfaceID> = []
        var screens: Set<ScreenID> = []
        /// Daemon events it holds, in arrival order.
        var events: [DaemonEventEnvelope] = []
        /// The first held event's sequence: the store's applied sequence stays below it.
        var firstHeld: UInt64?
        /// A held change of the workspace list's order (a move or group intent): every later order
        /// event waits too, since list indexes do not commute.
        var holdsList = false
        /// A held workspace delta: every later one waits too, since workspace revisions apply only
        /// in order.
        var holdsWorkspaceRevision = false
    }

    private weak var store: DaemonStore?
    /// The scopes whose intents are the batches', compared by identity. The stage keeps them while
    /// it is open, so no new scope can take an ended one's address.
    private var scopes: [DaemonCommandScope] = []
    /// The batches whose part has not ended.
    private var openBatches: [StoreStageBatch] = []
    private var hold = Hold()
    /// The highest sequence the store applied (or capped) while staged: it reaches it at commit.
    private var highestSeen: UInt64 = 0
    /// The stage's one deadline (a batch whose commit never comes does not hold the store).
    private var deadline: DemandTimer?
    /// Time left to the deadline, read on the clock of the batch that set it.
    private var deadlineRemaining: (() -> Duration)?
    public private(set) var isOpen = true

    init(store: DaemonStore) {
        self.store = store
    }

    /// The workspaces the stage holds (tests).
    var workspaces: Set<WorkspaceHandle> { hold.workspaces }
    /// The events the stage holds, in arrival order (tests).
    var events: [DaemonEventEnvelope] { hold.events }

    /// Joins one batch: its scope's intents are held from now on. The stage commits by itself at
    /// `deadline` on `clock`; the earliest deadline of the joined batches holds.
    func join<C: Clock>(scope: DaemonCommandScope?, until deadline: C.Instant, clock: C) -> StoreStageBatch where C.Duration == Duration {
        if let scope, !scopes.contains(where: { $0 === scope }) { scopes.append(scope) }
        let batch = StoreStageBatch(stage: self)
        openBatches.append(batch)
        let remaining = { clock.now.duration(to: deadline) }
        // The earliest deadline holds: a batch that joins later never keeps the stage open longer.
        guard deadlineRemaining.map({ remaining() < $0() }) ?? true else { return batch }
        deadlineRemaining = remaining
        let timer = self.deadline ?? DemandTimer(owner: "StoreStage.deadline", clock: clock)
        self.deadline = timer
        timer.schedule(after: max(remaining(), .zero)) { @MainActor [weak self] in self?.commitAll() }
        return batch
    }

    /// Ends `batch`'s part; the stage commits when every joined batch ended.
    func end(_ batch: StoreStageBatch) {
        openBatches.removeAll { $0 === batch }
        if openBatches.isEmpty { commitAll() }
    }

    /// Shows everything the stage holds, in one pass, and closes it.
    func commitAll() {
        guard isOpen else { return }
        close()
        guard let store, store.stage === self else { return }
        store.stage = nil
        let held = hold.events
        hold = Hold()
        store.intentLog.releaseHeld()
        // One pass: the held events onto the confirmed records, then every pending intent (the held
        // ones among them, in log order) back on top.
        let followup = held.isEmpty ? .none : store.apply(batch: held)
        if held.isEmpty { store.withOverlayLifted(writer: "stage commit") {} }
        if followup == .resync || store.needsResync {
            // A held event the store could not apply exactly: the applied sequence stays where the batch
            // left it (never past that event), and the snapshot brings the rest.
            store.resync()
            return
        }
        store.advanceAppliedSequence(to: highestSeen)
        if followup == .personal { store.refetchPersonal() }
    }

    /// Closes the stage without applying the events it holds: its connection ended, and the next
    /// one's snapshot is the daemon's truth (the held events and sequences are the old connection's).
    /// Held intents show again as pending.
    func discard() {
        guard isOpen else { return }
        close()
        hold = Hold()
        guard let store, store.stage === self else { return }
        store.stage = nil
        store.intentLog.releaseHeld()
        store.withOverlayLifted(writer: "stage discard") {}
    }

    private func close() {
        isOpen = false
        openBatches = []
        scopes = []
        deadline?.cancel()
        deadline = nil
        deadlineRemaining = nil
    }

    // MARK: Store hooks

    /// Whether `intent` is this stage's to hold: made under one of its scopes, of a kind that
    /// changes a tab or a workspace in place, in workspaces the store knows. Records them.
    func holds(_ intent: Intent, transaction: ClientTransactionID, in store: DaemonStore) -> Bool {
        guard isOpen, let scope = DaemonCommandScope.current, scopes.contains(where: { $0 === scope }),
              let reached = store.stageWorkspaces(of: intent), !reached.isEmpty else { return false }
        hold.workspaces.formUnion(reached)
        hold.transactions.insert(transaction)
        if Self.changesListOrder(intent) { hold.holdsList = true }
        return true
    }

    /// The events of `batch` the store applies now; the rest wait in the stage. A lifecycle event
    /// (the connection changed, the inbox overflowed) commits the stage first, and all apply; so
    /// does an event the stage would hold that a read-your-writes wait needs.
    func passing(_ batch: [DaemonEventEnvelope], in store: DaemonStore) -> [DaemonEventEnvelope] {
        guard isOpen else { return batch }
        if batch.contains(where: { store.stageReach(of: $0.event) == nil }) {
            commitAll()
            return batch
        }
        let before = hold
        var now: [DaemonEventEnvelope] = []
        for envelope in batch {
            guard let reach = heldReach(of: envelope, in: store) else {
                now.append(envelope)
                continue
            }
            if store.awaitsNow(envelope) {
                // A waiter needs it: nothing of this batch is held; what earlier batches held (lower
                // sequences) shows first, then the whole batch in order.
                hold = before
                commitAll()
                return batch
            }
            record(envelope, reach: reach)
        }
        return now
    }

    /// The workspaces `envelope` reaches when the stage holds it; nil when it passes.
    private func heldReach(of envelope: DaemonEventEnvelope, in store: DaemonStore) -> Set<WorkspaceHandle>? {
        let event = envelope.event
        let reach = store.stageReach(of: event) ?? []
        let echoesHeld = event.clientTransactionID.map(hold.transactions.contains) ?? false
        let namesHeld = store.stageSurface(of: event).map(hold.surfaces.contains) == true
            || store.stageScreen(of: event).map(hold.screens.contains) == true
        let ordered = (Self.changesListOrder(event) && hold.holdsList)
            || (Self.carriesWorkspaceRevision(event) && hold.holdsWorkspaceRevision)
        return echoesHeld || namesHeld || ordered || !reach.isDisjoint(with: hold.workspaces) ? reach : nil
    }

    private func record(_ envelope: DaemonEventEnvelope, reach: Set<WorkspaceHandle>) {
        let event = envelope.event
        hold.workspaces.formUnion(reach)
        if Self.changesListOrder(event) { hold.holdsList = true }
        if Self.carriesWorkspaceRevision(event) { hold.holdsWorkspaceRevision = true }
        switch event {
        case .tabAdded(let delta): hold.surfaces.insert(delta.surface)
        case .screenAdded(let delta): hold.screens.insert(delta.screen)
        default: break
        }
        hold.events.append(envelope)
        hold.firstHeld = hold.firstHeld.map { min($0, envelope.sequence) } ?? envelope.sequence
    }

    /// Whether a waiter for `sequence` (or for `transaction`'s echo) needs an event the stage holds:
    /// the store then commits the stage first, so a read-your-writes wait never waits on a script.
    func holds(through sequence: UInt64?, echo transaction: ClientTransactionID? = nil) -> Bool {
        guard isOpen else { return false }
        if let sequence, let firstHeld = hold.firstHeld, sequence >= firstHeld { return true }
        guard let transaction else { return false }
        return hold.events.contains { $0.event.clientTransactionID == transaction }
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

    /// Whether `event` carries a workspace revision (it applies only right after the one before).
    static func carriesWorkspaceRevision(_ event: DaemonEvent) -> Bool {
        switch event {
        case .workspaceAdded, .workspaceClosed, .workspaceRenamed, .workspaceMoved, .workspaceChanged: true
        default: false
        }
    }

    /// `sequence`, but below the first event the stage holds.
    func cappedSequence(_ sequence: UInt64) -> UInt64 {
        highestSeen = max(highestSeen, sequence)
        guard isOpen, let firstHeld = hold.firstHeld else { return sequence }
        return min(sequence, firstHeld &- 1)
    }
}
