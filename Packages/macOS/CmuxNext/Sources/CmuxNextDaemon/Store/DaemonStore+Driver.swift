import CmuxNextWakeups
import Foundation
import CmuxNextCompat

/// Off-main event buffer. The pump appends; the main actor takes whole
/// batches. At most one frame is requested per non-empty buffer.
///
/// Coalescing (plans/cmux-next/main-thread-budget.md): an event that states
/// the whole current value of one surface's field (title, size, scroll,
/// agent status, agent presence) replaces an earlier one for the same
/// surface still in the buffer, so a batch applies each object's newest
/// value once, however often it changed since the last frame. Workspace,
/// screen, pane and tab deltas are never coalesced: they carry consecutive
/// revisions and structural moves.
///
/// Bounded (architecture.md 5a): past `limit` events the buffer collapses
/// into one `.overflow` marker, which the store answers with one snapshot
/// that supersedes everything dropped. Lifecycle events and transaction
/// echoes (which settle intents and waiters) survive the collapse; every
/// other event is dropped until the next `take()`.
final class EventInbox: Sendable {
    fileprivate struct State {
        /// Buffered events in order; nil where a newer event of the same coalescing key replaced one.
        var events: [DaemonEventEnvelope?] = []
        /// Live (non-nil) entries of `events`.
        var live = 0
        /// The slot of the newest event per coalescing key (normal mode only).
        var latest: [CoalesceKey: Int] = [:]
        /// Events replaced by a newer one since creation (debug).
        var coalesced = 0
        var framePending = false
        /// Set once the buffer collapsed; cleared by `take()`.
        var collapsed = false
        var echoes: Set<ClientTransactionID> = []
    }

    /// Matches the daemon's own per-client mailbox.
    static let defaultLimit = 4096

    private let state = Mutex(State())
    private let limit: Int

    init(limit: Int = EventInbox.defaultLimit) {
        self.limit = max(limit, 1)
    }

    /// Returns true when the caller must schedule a frame.
    func append(_ envelope: DaemonEventEnvelope) -> Bool {
        state.withLock { state in
            if state.collapsed {
                Self.keep(envelope, in: &state)
            } else if let key = CoalesceKey(envelope.event), let old = state.latest[key] {
                // The newest value of the same field of the same surface: the older one never applies.
                state.events.modify(checked: old) { $0 = nil }
                state.coalesced += 1
                state.latest[key] = state.events.count
                state.events.append(envelope)
            } else if state.live >= limit {
                let buffered = state.events.compactMap { $0 }
                state.events = [DaemonEventEnvelope(sequence: envelope.sequence, event: .overflow("app event inbox exceeded \(limit) events"))]
                state.live = 1
                state.latest.removeAll(keepingCapacity: true)
                state.collapsed = true
                for old in buffered { Self.keep(old, in: &state) }
                Self.keep(envelope, in: &state)
            } else {
                if let key = CoalesceKey(envelope.event) { state.latest[key] = state.events.count }
                state.events.append(envelope)
                state.live += 1
            }
            guard !state.framePending else { return false }
            state.framePending = true
            return true
        }
    }

    /// Puts events a batch did not reach (its frame's budget was spent) back in front of the
    /// buffer, so they apply first on the next frame. A newer buffered event of the same
    /// coalescing key still wins. Returns true when the caller must schedule a frame.
    func putBack<Events: Sequence>(_ rest: Events) -> Bool where Events.Element == DaemonEventEnvelope {
        state.withLock { state in
            let merged = Array(rest) + state.events.compactMap { $0 }
            state.events.removeAll(keepingCapacity: true)
            state.latest.removeAll(keepingCapacity: true)
            state.live = 0
            for envelope in merged {
                if !state.collapsed, let key = CoalesceKey(envelope.event) {
                    if let old = state.latest[key] {
                        state.events.modify(checked: old) { $0 = nil }
                        state.live -= 1
                        state.coalesced += 1
                    }
                    state.latest[key] = state.events.count
                }
                state.events.append(envelope)
                state.live += 1
            }
            guard !state.framePending else { return false }
            state.framePending = true
            return true
        }
    }

    /// Events a newer one replaced so far (debug).
    var coalescedCount: Int { state.withLock { $0.coalesced } }

    /// While collapsed: keep lifecycle and bookmark events and one echo per transaction
    /// (as a `tree-changed` carrying it), drop the rest.
    private static func keep(_ envelope: DaemonEventEnvelope, in state: inout State) {
        switch envelope.event {
        case .connected, .disconnected, .daemonShutdown, .sessionState:
            // Session state: not in the snapshot the collapse refetches.
            state.append(envelope)
        case .terminalRegistryChanged:
            // Only an invalidation: keep the newest from each original control
            // connection. A replacement source must not inherit the old stamp.
            state.removeAll {
                if case .terminalRegistryChanged = $0.event {
                    return $0.sourceID == envelope.sourceID && $0.connectionSerial == envelope.connectionSerial
                }
                return false
            }
            state.append(envelope)
        case .agentChanged(let status):
            // Agent state is not in the snapshot either (cx-ag5.6.8). Each event is the whole state
            // of one surface, so a collapsed inbox keeps only the newest one per surface.
            state.removeAll { if case .agentChanged(let held) = $0.event { held.surface == status.surface } else { false } }
            state.append(envelope)
        case .notification:
            // Its text is not in the snapshot either (`outlivesSnapshot`).
            state.append(envelope)
        case .agentPresenceChanged(let presence):
            state.removeAll {
                if case .agentPresenceChanged(let held) = $0.event { held.surface == presence.surface } else { false }
            }
            state.append(envelope)
        case .bookmarksChanged, .historyChanged, .keybindingsChanged, .conversationChanged, .conversationTyping, .conversationDraft, .conversationLive, .conversationRunChanged, .cloudConversations,
             .terminalClipboardRead, .terminalClipboardReadCancelled, .unknown:
            // Not part of the tree snapshot a resync refetches (.unknown: the `apps-*` events of apps-v1).
            state.append(envelope)
        default:
            guard let transaction = envelope.event.clientTransactionID, state.echoes.insert(transaction).inserted else { return }
            state.append(DaemonEventEnvelope(sequence: envelope.sequence, event: .treeChanged(transaction: transaction)))
        }
    }

    /// Takes everything buffered and clears the pending-frame flag.
    func take() -> [DaemonEventEnvelope] {
        state.withLock { state in
            state.framePending = false
            state.collapsed = false
            state.echoes.removeAll(keepingCapacity: true)
            state.latest.removeAll(keepingCapacity: true)
            state.live = 0
            defer { state.events.removeAll(keepingCapacity: true) }
            return state.events.compactMap { $0 }
        }
    }

    /// Keeps new events from scheduling frames (during a resync).
    func hold() {
        state.withLock { $0.framePending = true }
    }
}

extension EventInbox.State {
    /// Appends a live event (collapsed mode; no coalescing key is tracked there).
    mutating func append(_ envelope: DaemonEventEnvelope) {
        events.append(envelope)
        live += 1
    }

    /// Removes the live events `predicate` matches (collapsed mode).
    mutating func removeAll(where predicate: (DaemonEventEnvelope) -> Bool) {
        events = events.compactMap { $0 }.filter { !predicate($0) }
        live = events.count
    }
}

struct StoreDriver {
    let connection: DaemonConnection
    let inbox: EventInbox
    let scheduler: any FrameBatchScheduler
}

extension DaemonStore {
    /// Mirrors the daemon until the connection closes. The event stream is
    /// consumed off the main actor; batches reach the main actor at most once
    /// per frame. A batch that invalidates the tree triggers one snapshot,
    /// fetched and decoded off the main actor; events it supersedes (by
    /// sequence barrier) are dropped. No polling and no timers.
    public func run(connection: DaemonConnection, scheduler: any FrameBatchScheduler = NextTurnFrameScheduler()) async {
        let driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: scheduler)
        self.driver = driver
        beginConnection()
        let pump = Task.detached { [weak self] () -> String? in
            do {
                for try await envelope in connection.events where driver.inbox.append(envelope) {
                    driver.scheduler.scheduleFrame { self?.drain() }
                }
                return nil
            } catch {
                return String(describing: error)
            }
        }
        let failure = await pump.value
        drain()
        // The connection is gone: no echo or barrier will come for its commands.
        drainAppliedWaiters = true
        flushAppliedWaiters()
        if let failure { markFailed(failure) }
        resumeRefreshWaiters()
        resyncRetry?.cancel()
        resyncRetry = nil
        needsResync = false
        resyncPacer.reset()
        personalRefetch = PersonalRefetch()
        self.driver = nil
    }

    /// Events applied per budget check: one slice amortizes a batch's fixed work (intents lifted
    /// and reapplied, waiters settled) over its events, and stays far below the visible budget
    /// (a workspace or tab delta applies in microseconds).
    static let drainSlice = 32

    /// Applies what is buffered, in slices, while the frame's visible budget lets it
    /// (``MainFrameBudget``, plans/cmux-next/main-thread-budget.md): the rest goes back to the
    /// front of the inbox and applies on the next frame. The first slice of a frame always applies.
    func drain() {
        guard let driver, !isResyncing else { return }
        let batch = driver.inbox.take()
        guard !batch.isEmpty else { return }
        let budget = driver.scheduler.mainFrameBudget
        var rest = ArraySlice(batch)
        while !rest.isEmpty {
            let slice = Array(rest.prefix(Self.drainSlice))
            rest = rest.dropFirst(Self.drainSlice)
            let connected = slice.contains { if case .connected = $0.event { true } else { false } }
            // A snapshot that failed past its retry budget is retried on the
            // next daemon event (something changed), not on a timer.
            let followup = apply(batch: slice)
            if followup == .resync || needsResync {
                // The snapshot supersedes what is left; the inbox holds it until the resync drains.
                if !rest.isEmpty { _ = driver.inbox.putBack(rest) }
                resync(seedAgents: connected)
                return
            } else if followup == .personal {
                refetchPersonal()
            }
            if !rest.isEmpty, let budget, !budget.mayRun(.visible) {
                if driver.inbox.putBack(rest) {
                    driver.scheduler.scheduleFrame { [weak self] in self?.drain() }
                }
                return
            }
        }
    }

    /// Fetches `list-personal` alone and applies it (`personal-changed`: a group's fold, a room
    /// edit). The tree is not refetched: a fold costs the personal state, never every workspace,
    /// screen and tab (plans/cmux-next/state-ownership-DESIGN.md). The applied sequence stays
    /// below the personal change until it lands, so a read-your-writes waiter sees it. A failed
    /// fetch falls back to a resync; a snapshot meanwhile supersedes it.
    func refetchPersonal() {
        guard let driver else { return }
        guard !personalRefetch.inFlight else { personalRefetch.again = true; return }
        personalRefetch.inFlight = true
        let covering = personalRefetch.seen
        let barrier = snapshotBarrier
        // task-owner: at most one list-personal at a time (personalRefetch.inFlight); its request has the connection's deadline
        Task { @MainActor in
            let state = try? await driver.connection.listPersonal()
            personalRefetch.inFlight = false
            guard self.driver != nil else { return }
            guard let state else { return resync() }
            // A snapshot that landed or is landing holds this personal state or a newer one; a change after
            // its barrier is fetched once it lands (`snapshotCoveredPersonal`, or `again` below).
            if !isResyncing, snapshotBarrier == barrier, personalRefetch.pending != nil {
                withOverlayLifted(writer: "personal refetch") { applyPersonal(state) }
                advanceAppliedSequence(to: personalRefetch.landed(covering: covering))
            }
            if personalRefetch.again {
                personalRefetch.again = false
                refetchPersonal()
            }
        }
    }

    /// Fetches and applies a snapshot, then flushes events held meanwhile.
    ///
    /// A failed snapshot (the daemon busy past the deadline, a transient
    /// error) is retried with a capped backoff (`RetryPolicy.resync`), and
    /// after its budget on the next daemon event. Without the retry the tree
    /// stayed stale until some later event needed another resync; without
    /// the budget a wedged daemon was asked for a snapshot every 2 s forever.
    func resync(seedAgents: Bool = false) {
        guard let driver, !isResyncing else { return }
        isResyncing = true
        // This snapshot is requested after every waiting `refresh()` call.
        let refreshing = refreshWaiters
        refreshWaiters.removeAll()
        needsResync = false
        resyncRetry?.cancel()
        resyncRetry = nil
        driver.inbox.hold()
        // task-owner: at most one resync at a time (isResyncing); its snapshot request has a deadline
        Task { @MainActor in
            var failed = false
            do {
                let (tree, barrier) = try await driver.connection.snapshot()
                // The comparison with the last applied snapshot reads the whole tree: off the main
                // thread. Main applies only what differs (or everything, when the memo cannot vouch).
                let memo = snapshotMemo
                let diff = memo.applied.isEmpty ? nil : await SnapshotDiff.computed(tree, against: memo.applied, revision: memo.revision)
                apply(snapshot: tree, diff: diff)
                snapshotBarrier = max(snapshotBarrier, barrier)
                snapshotCoveredPersonal(through: barrier)
                advanceAppliedSequence(to: barrier)
                resyncPacer.reset()
                if seedAgents { apply(agents: try await driver.connection.agents()) }
            } catch {
                logger.error("resync failed: \(String(describing: error), privacy: .public)")
                failed = true
            }
            isResyncing = false
            if failed {
                scheduleResyncRetry(seedAgents: seedAgents)
                // The retry serves them; without one (disconnected or
                // budget spent) they return now with what the store has.
                refreshWaiters.insert(contentsOf: refreshing, at: 0)
                if resyncRetry == nil { resumeRefreshWaiters() }
            } else {
                for waiter in refreshing { waiter.resume() }
            }
            if !failed, !refreshWaiters.isEmpty {
                // Asked while this snapshot was in flight: fetch one after it.
                return resync()
            }
            drain()
        }
    }

    /// Fetches a snapshot through the driver's resync (inbox hold, snapshot
    /// barrier, intents lifted and reapplied) and returns once one requested
    /// after this call is applied, or at once when no connection drives the
    /// store. A failed snapshot returns too (after its retries), and the
    /// store keeps what it had.
    public func refresh() async {
        guard driver != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            refreshWaiters.append(continuation)
            // A resync in flight was requested before this call: it fetches
            // another one when it finishes.
            if !isResyncing, resyncRetry == nil { resync() }
        }
    }

    func resumeRefreshWaiters() {
        let waiting = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    private func scheduleResyncRetry(seedAgents: Bool) {
        // While disconnected the reconnect's `connected` event resyncs anyway.
        guard driver != nil, case .connected = connectionState else { return }
        guard let delay = resyncPacer.failed() else {
            logger.error("resync retries spent; the next daemon event resyncs")
            needsResync = true
            return
        }
        let timer = DemandTimer(owner: "DaemonStore.resync", clock: resyncClock)
        resyncRetry = timer
        timer.schedule(after: delay) { @MainActor [weak self] in
            guard let self, self.driver != nil, self.resyncRetry === timer else { return }
            self.resyncRetry = nil
            self.resync(seedAgents: seedAgents)
        }
    }
}
