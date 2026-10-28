/// The idle scheduler's promotion, node records and task bookkeeping (IdleScheduler.swift has
/// the periods and the timer).
extension IdleScheduler {
    /// Counters for `debug.main_budget` (its `idle` member) and the tests.
    public struct Stats: Sendable, Equatable {
        /// Long idle periods started (no frame expected).
        public var longPeriods = 0
        /// Short idle periods started (between a frame's end and the next frame).
        public var shortPeriods = 0
        /// Idle tasks run in idle periods.
        public var tasks = 0
        /// Tasks moved to background because their `maxDelay` passed.
        public var promoted = 0
        /// Tasks dropped because their node was released.
        public var dropped = 0
        /// Idle periods that pending input ended.
        public var endedByInput = 0
        /// Idle periods that higher-class work (a post, a display link) ended.
        public var endedByHigherWork = 0
        /// Times the period timer fired.
        public var timerFires = 0
    }

    // MARK: Promotion

    /// Moves every task past its `maxDelay` to the background class, in expiry order.
    func promoteExpired(_ now: UInt64) {
        guard expiring > 0 else { return }
        var expired: [IdleTask] = []
        while let top = expiries.top, top.nanos <= now {
            expiries.pop()
            guard top.task.state != .done else { continue }
            finish(top.task)
            expired.append(top.task)
        }
        compact()
        // After the walk: posting can start the budgeted link, which reschedules.
        for task in expired {
            guard let record = task.record else {
                stats.promoted += 1
                send(task)
                continue
            }
            guard let node = record.node else {
                task.body = nil
                stats.dropped += 1
                releaseIfEmpty(record)
                continue
            }
            stats.promoted += 1
            if node.isVisible, !node.isFrozen {
                send(task)
                releaseIfEmpty(record)
            } else {
                record.held.append(task)
                held += 1
                requestHiddenWake(record)
            }
        }
    }

    private func send(_ task: IdleTask) {
        guard let body = task.body, let promote else { return }
        task.body = nil
        let uptimeNanos = uptimeNanos
        promote(task.owner, task.site) {
            body(IdleDeadline(deadlineNanos: 0, didTimeout: true, uptimeNanos: uptimeNanos))
        }
    }

    /// Sends a record's held tasks while its node may run background work: visible, or at a hidden
    /// wake (`atWake`), and not frozen.
    private func sendHeld(_ record: IdleNodeRecord, atWake: Bool) {
        guard !record.held.isEmpty, let node = record.node, !node.isFrozen, atWake || node.isVisible else { return }
        let tasks = record.held
        record.held = []
        held -= tasks.count
        for task in tasks {
            send(task)
        }
        releaseIfEmpty(record)
    }

    private func requestHiddenWake(_ record: IdleNodeRecord) {
        guard !record.wakeRequested, let wake = hiddenWake?() else { return }
        record.wakeRequested = true
        wake("IdleScheduler.promoted") { [weak self, weak record] in
            guard let self, let record else { return }
            record.wakeRequested = false
            if record.node == nil {
                self.sweepReleased()
            } else {
                self.sendHeld(record, atWake: true)
            }
        }
    }

    // MARK: Records

    /// The record of `node`, made with its one subscription on the node's first task.
    func record(for node: VisibilityNode) -> IdleNodeRecord {
        let id = ObjectIdentifier(node)
        if let record = records[id], record.node === node { return record }
        // A released node's address, reused: its record's waiting tasks are dropped now.
        if let stale = records[id] { dropWaiting(stale) }
        let record = IdleNodeRecord(id: id, node: node)
        record.subscription = node.subscribe(owner: "IdleScheduler.node") { [weak self, weak record] visibility in
            guard let self, let record else { return }
            self.nodeFlipped(record, visibility)
        }
        records[id] = record
        return record
    }

    /// A node with tasks flipped: on show its parked tasks go back to the run queue (in their
    /// order, after the tasks posted meanwhile) and, when visible, its held tasks are sent.
    private func nodeFlipped(_ record: IdleNodeRecord, _ visibility: Visibility) {
        guard visibility != .hidden else { return }
        let tasks = record.parked
        record.parked = []
        for task in tasks where task.state == .parked {
            task.state = .queued
            parked -= 1
            queued += 1
            slots.append(task)
        }
        sendHeld(record, atWake: false)
        if !tasks.isEmpty { reschedule() }
    }

    /// Drops the waiting tasks of records whose node was released; called when a period drained
    /// the run queue and at hidden wakes, so a released node's closures do not outlive the next one.
    func sweepReleased() {
        guard parked > 0 || held > 0 else { return }
        for record in records.values where record.node == nil {
            dropWaiting(record)
        }
    }

    private func dropWaiting(_ record: IdleNodeRecord) {
        for task in record.parked where task.state == .parked {
            drop(task)
        }
        record.parked = []
        for task in record.held {
            task.body = nil
        }
        stats.dropped += record.held.count
        held -= record.held.count
        record.held = []
        releaseIfEmpty(record)
    }

    func releaseIfEmpty(_ record: IdleNodeRecord) {
        guard record.tasks == 0, record.held.isEmpty, records[record.id] === record else { return }
        records[record.id] = nil
    }

    // MARK: Queue

    /// Takes a queued or parked task out of the counts (it ran, moved or was dropped).
    func finish(_ task: IdleTask) {
        switch task.state {
        case .queued: queued -= 1
        case .parked: parked -= 1
        case .done: return
        }
        task.state = .done
        if task.expiresNanos != nil { expiring -= 1 }
        task.record?.tasks -= 1
    }

    func drop(_ task: IdleTask) {
        finish(task)
        task.body = nil
        stats.dropped += 1
        if let record = task.record { releaseIfEmpty(record) }
    }

    func earliestExpiry() -> UInt64? {
        guard expiring > 0 else {
            expiries.removeAll()
            return nil
        }
        // Finished tasks deep in the heap: drop them once they are most of it.
        if expiries.count > 64, expiries.count > 2 * expiring { expiries.removeAll { $0.state == .done } }
        while let top = expiries.top, top.task.state == .done { expiries.pop() }
        return expiries.top?.nanos
    }
}
