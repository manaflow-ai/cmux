import CmuxNextWakeups
import Foundation
import Synchronization

/// Off-main event buffer. The pump appends; the main actor takes whole
/// batches. At most one frame is requested per non-empty buffer.
///
/// Bounded (architecture.md 5a): past `limit` events the buffer collapses
/// into one `.overflow` marker, which the store answers with one snapshot
/// that supersedes everything dropped. Lifecycle events and transaction
/// echoes (which settle intents and waiters) survive the collapse; every
/// other event is dropped until the next `take()`.
final class EventInbox: Sendable {
    private struct State {
        var events: [DaemonEventEnvelope] = []
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
            } else if state.events.count >= limit {
                let buffered = state.events
                state.events = [DaemonEventEnvelope(sequence: envelope.sequence, event: .overflow("app event inbox exceeded \(limit) events"))]
                state.collapsed = true
                for old in buffered { Self.keep(old, in: &state) }
                Self.keep(envelope, in: &state)
            } else {
                state.events.append(envelope)
            }
            guard !state.framePending else { return false }
            state.framePending = true
            return true
        }
    }

    /// While collapsed: keep lifecycle and bookmark events and one echo per transaction
    /// (as a `tree-changed` carrying it), drop the rest.
    private static func keep(_ envelope: DaemonEventEnvelope, in state: inout State) {
        switch envelope.event {
        case .connected, .disconnected, .daemonShutdown, .sessionState:
            // Session state: not in the snapshot the collapse refetches.
            state.events.append(envelope)
        case .bookmarksChanged, .conversationChanged, .conversationTyping, .cloudConversations,
             .terminalClipboardRead, .terminalClipboardReadCancelled:
            // Not part of the tree snapshot a resync refetches.
            state.events.append(envelope)
        default:
            guard let transaction = envelope.event.clientTransactionID, state.echoes.insert(transaction).inserted else { return }
            state.events.append(DaemonEventEnvelope(sequence: envelope.sequence, event: .treeChanged(transaction: transaction)))
        }
    }

    /// Takes everything buffered and clears the pending-frame flag.
    func take() -> [DaemonEventEnvelope] {
        state.withLock { state in
            state.framePending = false
            state.collapsed = false
            state.echoes.removeAll(keepingCapacity: true)
            defer { state.events.removeAll(keepingCapacity: true) }
            return state.events
        }
    }

    /// Keeps new events from scheduling frames (during a resync).
    func hold() {
        state.withLock { $0.framePending = true }
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
        self.driver = nil
    }

    /// Applies everything buffered as one batch.
    func drain() {
        guard let driver, !isResyncing else { return }
        let batch = driver.inbox.take()
        guard !batch.isEmpty else { return }
        let connected = batch.contains { if case .connected = $0.event { true } else { false } }
        // A snapshot that failed past its retry budget is retried on the
        // next daemon event (something changed), not on a timer.
        if apply(batch: batch) == .resync || needsResync {
            resync(seedAgents: connected)
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
                apply(snapshot: tree)
                snapshotBarrier = max(snapshotBarrier, barrier)
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
