import CmuxNextWakeups

/// The frame drain of the event inbox and its tail (``DrainTail``).
extension DaemonStore {
    /// The frame drain: applies, as one batch, everything up to and including the last transaction a
    /// person or the app's frontend caused, or a read-your-writes wait needs (with the tail before it,
    /// when there is one), so the echo
    /// of a person's action with no intent (close other tabs, close a workspace from the palette)
    /// shows in the frame after it arrives, after what the daemon sent before it and whatever else
    /// is queued. The transactions after it go to the tail, which applies them in budgeted tasks; a
    /// store with no ``drainTailScheduler`` applies the whole batch here. A daemon transaction (close
    /// twelve panes and the layout change; ``TransactionRun``) is never split. The batch's cost is what changed since the
    /// last frame: whole-value events coalesce in the inbox, a snapshot applies only what differs
    /// (DaemonStore+SnapshotDiff.swift), the unread sum and the workspace-list check cost the
    /// workspaces that joined, left or changed their own count, and the sidebar is flattened only by
    /// a batch that changed the order, the membership or a group. Each batch is one sample of
    /// ``drainCost``.
    ///
    /// - Parameter flushingTail: Applies the whole tail and the whole batch (after a snapshot, at the
    ///   end of a connection).
    func drain(flushingTail: Bool = false) {
        guard let driver, !isResyncing else { return }
        let batch = driver.tail.frame(driver.inbox.take(), flushing: flushingTail) { awaitsNow($0) }
        if !batch.isEmpty {
            let connected = batch.contains { if case .connected = $0.event { true } else { false } }
            // A snapshot that failed past its retry budget is retried on the
            // next daemon event (something changed), not on a timer.
            let (followup, cost) = DrainCost.measured(on: drainClock) { apply(batch: batch) }
            drainCost.record(cost, events: batch.count)
            if followup == .resync || needsResync {
                causes.resync = max(causes.resync, batch.lazy.map(\.cause).max() ?? .program)
                // The tail waits for the snapshot, which applies it (`resync`).
                return resync(seedAgents: connected)
            }
            if followup == .personal { refetchPersonal() }
        }
        postDrainTail(driver.tail)
    }

    /// Transactions the frame drain left for budgeted tasks (tests, diagnostics).
    var drainTailCount: Int { driver?.tail.count ?? 0 }

    /// Applies now, as the frame does, the tail's transactions through the last one with an event
    /// `awaited` matches: a read-your-writes wait (the person's action waiting on its reply's event
    /// sequence) never waits on the automation share, as it never waits on a script batch's stage.
    func applyAwaitedTail(_ awaited: (DaemonEventEnvelope) -> Bool) {
        // Inside an apply the tail is newer than the batch applying: it waits for the next frame or task.
        guard applyDepth == 0, let driver, !isResyncing else { return }
        let batch = driver.tail.take(through: awaited)
        guard !batch.isEmpty else { return }
        let (followup, cost) = DrainCost.measured(on: drainClock) { apply(batch: batch) }
        drainCost.record(cost, events: batch.count)
        if followup == .resync || needsResync {
            causes.resync = max(causes.resync, batch.lazy.map(\.cause).max() ?? .program)
            return resync()
        }
        if followup == .personal { refetchPersonal() }
    }

    private func postDrainTail(_ tail: DrainTail) {
        tail.post { [weak self] workClass in self?.runDrainTail(tail, as: workClass) }
    }

    /// One task of the tail, in `workClass`: the head transaction, then the next ones while they
    /// share the class, the slice and the class share last. Each transaction applies as its own
    /// batch, so read-your-writes waiters advance per transaction. One that needs a snapshot starts
    /// it, and the rest of the tail waits for it.
    private func runDrainTail(_ tail: DrainTail, as workClass: BudgetedWorkClass) {
        // A task of a connection that ended, or one a snapshot will flush.
        guard let driver, driver.tail === tail, !isResyncing, let head = tail.headClass else { return }
        // A flush emptied the tail after the post, and transactions of another class came in.
        guard head == workClass else { return postDrainTail(tail) }
        let ((resyncCause, events), cost) = DrainCost.measured(on: drainClock) {
            applyTailSlice(tail, as: workClass, clock: drainClock)
        }
        drainCost.record(cost, events: events)
        guard let resyncCause else { return postDrainTail(tail) }
        causes.resync = max(causes.resync, resyncCause)
        resync()
    }

    /// Applies whole transactions from the head of `tail` as ``runDrainTail(_:as:)`` says. Returns the
    /// cause of the transaction that needs a snapshot (nil: none) and how many events it applied.
    private func applyTailSlice<C: Clock>(_ tail: DrainTail, as workClass: BudgetedWorkClass,
                                          clock: C) -> (resync: ObservationCause?, events: Int) where C.Duration == Duration {
        let start = clock.now
        var events = 0
        while let transaction = tail.takeHead() {
            events += transaction.envelopes.count
            let followup = apply(batch: transaction.envelopes)
            if followup == .resync || needsResync { return (transaction.cause, events) }
            if followup == .personal { refetchPersonal() }
            guard tail.headClass == workClass, start.duration(to: clock.now) < DrainTail.slice,
                  tail.scheduler?.drainTailMayContinue(workClass) == true else { break }
        }
        return (nil, events)
    }
}
