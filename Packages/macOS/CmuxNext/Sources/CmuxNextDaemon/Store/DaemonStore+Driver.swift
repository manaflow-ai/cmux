import CmuxNextWakeups
import Foundation
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

struct StoreDriver {
    let connection: DaemonConnection
    let inbox: EventInbox
    let scheduler: any FrameBatchScheduler
    /// The transactions the frame drain left for budgeted tasks (``DrainTail``).
    let tail: DrainTail
    /// The resync's snapshot read: the connection's, or a test's.
    let snapshot: @MainActor @Sendable () async throws -> (tree: DaemonTree, barrier: UInt64)

    @MainActor
    init(connection: DaemonConnection, inbox: EventInbox, scheduler: any FrameBatchScheduler, tail: (any DrainTailScheduler)? = nil,
         tailLimit: Int = EventInbox.defaultLimit,
         snapshot: (@MainActor @Sendable () async throws -> (tree: DaemonTree, barrier: UInt64))? = nil) {
        (self.connection, self.inbox, self.scheduler) = (connection, inbox, scheduler)
        self.tail = DrainTail(scheduler: tail, limit: tailLimit)
        self.snapshot = snapshot ?? { try await connection.snapshot() }
    }

    /// Buffers `envelope` and asks for one drain frame when the inbox had none pending. Runs on the
    /// thread that produced the event (the connection's reader for daemon events).
    func deliver(_ envelope: DaemonEventEnvelope, drain: @escaping @MainActor @Sendable () -> Void) {
        if inbox.append(envelope) { scheduler.scheduleFrame(drain) }
    }
}

extension DaemonStore {
    /// Mirrors the daemon until the connection closes. Events go from the
    /// connection's reader thread straight into the inbox
    /// (``DaemonConnection/consumeEvents(_:)``: no cooperative-pool job on the
    /// echo path); only those the connection held before this run (its bounded
    /// ``EventInbox`` backlog, ``DaemonEventRoute``) pass through the pump task,
    /// once, when it attaches. The connection's gate and backlog never hold more
    /// than their limit; the store's inbox, which each frame empties, collapses
    /// past its limit too: a flood ends in one resync.
    /// Batches reach the main actor at most once per frame. A batch that
    /// invalidates the tree triggers one snapshot, fetched and decoded off
    /// the main actor; events it supersedes (by sequence barrier) are
    /// dropped. No polling and no timers.
    public func run(connection: DaemonConnection, scheduler: any FrameBatchScheduler) async {
        await run(driver: StoreDriver(connection: connection, inbox: EventInbox(), scheduler: scheduler, tail: drainTailScheduler))
    }

    /// ``run(connection:scheduler:)`` with its driver made: a test's injects the resync's snapshot read.
    func run(driver: StoreDriver) async {
        let connection = driver.connection
        self.driver = driver
        beginConnection()
        let pump = Task.detached { [weak self] () -> String? in
            do {
                try await connection.consumeEvents { envelope in driver.deliver(envelope) { self?.drain() } }
                return nil
            } catch {
                return String(describing: error)
            }
        }
        let failure = await pump.value
        // Everything left, the tail first: a frame asked for after this would find no driver.
        drain(flushingTail: true)
        // What a script batch's stage still holds is this connection's, and a commit now could start a resync on
        // it: dropped (held intents show again as pending); the next connection's snapshot is the truth.
        stage?.discard()
        // The connection is gone: no echo or barrier will come for its commands.
        drainAppliedWaiters = true
        flushAppliedWaiters()
        // A close, a pump failure or an incompatible daemon ends the stream with no `disconnected` event.
        endAppliedWaits()
        if let failure { markFailed(failure) }
        resumeRefreshWaiters()
        resyncRetry?.cancel()
        resyncRetry = nil
        needsResync = false
        causes.resync = .program
        resyncPacer.reset()
        personalRefetch = PersonalRefetch()
        self.driver = nil
    }

    /// Clears ``drainCost`` (`debug.drain_cost` with `reset`).
    public func resetDrainCost() {
        drainCost = DrainCost()
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
        // task-owner: at most one list-personal at a time (personalRefetch.inFlight); its request has the connection's
        // deadline. Off main: the task awaits the request; its one step on main is `personalFetched` (recipe R-hop).
        Task { @concurrent [self] in
            let state = try? await driver.connection.listPersonal()
            await personalFetched(state, covering: covering, barrier: barrier)
        }
    }

    /// The `list-personal` that `refetchPersonal` sent answered `state` (nil: it failed, so a resync follows).
    private func personalFetched(_ state: PersonalState?, covering: UInt64, barrier: UInt64) {
        personalRefetch.inFlight = false
        guard driver != nil else { return }
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
        // Batches that ask for a resync while this one is in flight raise the next one's cause.
        let cause = causes.resync
        causes.resync = .program
        driver.inbox.hold()
        let logger = logger
        // task-owner: at most one resync at a time (isResyncing); its snapshot request has a deadline. Off main: the
        // task awaits the snapshot, its diff and the agents; its steps on main (under the inbox hold, so no batch
        // drains meanwhile) are `resyncFetched` and `resyncEnded` (recipe R-hop).
        Task { @concurrent [self] in
            var failed = false
            do {
                let (tree, barrier) = try await driver.snapshot()
                // The comparison with the last applied snapshot reads the whole tree: off the main
                // thread. Main applies only what differs (or everything, when the memo cannot vouch).
                let diff = await snapshotDiff(of: tree)
                await resyncFetched(tree, diff: diff, barrier: barrier, cause: cause)
                if seedAgents {
                    let agents = try await driver.connection.agents()
                    await apply(agents: agents)
                }
            } catch {
                logger.error("resync failed: \(String(describing: error), privacy: .public)")
                failed = true
            }
            await resyncEnded(failed: failed, refreshing: refreshing, seedAgents: seedAgents, cause: cause)
        }
    }

    /// The resync's snapshot arrived: applies what differs, in the cause of the batches that asked for it.
    private func resyncFetched(_ tree: DaemonTree, diff: SnapshotDiff?, barrier: UInt64, cause: ObservationCause) {
        withCause(cause) { apply(snapshot: tree, diff: diff) }
        snapshotBarrier = max(snapshotBarrier, barrier)
        snapshotCoveredPersonal(through: barrier)
        advanceAppliedSequence(to: barrier)
        resyncPacer.reset()
    }

    /// The resync ended (`failed`: its snapshot did not apply): a retry or the next one, the `refresh()` callers it
    /// serves, and the events held meanwhile.
    private func resyncEnded(failed: Bool, refreshing: [OnceContinuation<Void, OnceContinuationError>], seedAgents: Bool,
                             cause: ObservationCause) {
        isResyncing = false
        if failed {
            scheduleResyncRetry(seedAgents: seedAgents)
            // A retry applies what this one would have, with its cause; without one, the batch
            // that resyncs next names its own.
            if resyncRetry != nil { causes.resync = max(causes.resync, cause) }
            // The retry serves them; without one (disconnected or
            // budget spent) they return now with what the store has.
            refreshWaiters.insert(contentsOf: refreshing, at: 0)
            if resyncRetry == nil { resumeRefreshWaiters() }
        } else {
            for waiter in refreshing { waiter.resume(returning: ()) }
        }
        if !failed, !refreshWaiters.isEmpty {
            // Asked while this snapshot was in flight: fetch one after it.
            return resync()
        }
        // The tail held meanwhile applies in this frame too: the snapshot superseded most of it.
        drain(flushingTail: true)
    }

    /// Fetches a snapshot through the driver's resync (inbox hold, snapshot
    /// barrier, intents lifted and reapplied) and returns once one requested
    /// after this call is applied, or at once when no connection drives the
    /// store. A failed snapshot returns too (after its retries), and the
    /// store keeps what it had, as does a waiter dropped unresumed.
    public func refresh() async {
        guard driver != nil else { return }
        _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            refreshWaiters.append(continuation)
            // A resync in flight was requested before this call: it fetches
            // another one when it finishes.
            if !isResyncing, resyncRetry == nil { resync() }
        }
    }

    /// Runs `work` once the first live snapshot is applied to the store (at once when it has
    /// been): the startup phase's first-snapshot reference (`StartupPhase.Reference.firstSnapshot`,
    /// Chrome's after-startup reference count in `chrome/browser/after_startup_task_utils.cc`).
    /// A launch snapshot (``applyProvisional(snapshot:)``) does not count.
    public func whenFirstSnapshotApplied(_ work: @escaping @MainActor () -> Void) {
        if isLoaded { work() } else { firstSnapshotWaiters.append(work) }
    }

    /// Runs the first-snapshot waiters once ``isLoaded`` holds (after the snapshot's overlay and
    /// applied waiters); later snapshots find none.
    func runFirstSnapshotWaiters() {
        guard isLoaded, !firstSnapshotWaiters.isEmpty else { return }
        let waiting = firstSnapshotWaiters
        firstSnapshotWaiters.removeAll()
        for work in waiting { work() }
    }

    func resumeRefreshWaiters() {
        let waiting = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiting { waiter.resume(returning: ()) }
    }

    private func scheduleResyncRetry(seedAgents: Bool) {
        // While disconnected the reconnect's `connected` event resyncs anyway.
        guard driver != nil, case .connected = connectionState else { return }
        guard let delay = resyncPacer.failed() else {
            logger.error("resync retries spent; the next daemon event resyncs")
            needsResync = true
            return
        }
        // A visible deadline on the app's wake-up queue: the retried snapshot is what the windows show.
        let retry = deadlines.deadline(owner: "DaemonStore.resync", workClass: .visible)
        resyncRetry = retry
        retry.schedule(after: delay) { [weak self] in
            guard let self, self.driver != nil, self.resyncRetry === retry else { return }
            self.resyncRetry = nil
            self.resync(seedAgents: seedAgents)
        }
    }
}
