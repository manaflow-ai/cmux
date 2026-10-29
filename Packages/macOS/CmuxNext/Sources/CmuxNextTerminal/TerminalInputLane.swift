public import Foundation
import CmuxNextCompat
import Darwin

/// A session's input on its way to the ``TerminalIO``: a ring of records the main thread fills with
/// no wait and no allocation of its own, drained on the IO's queue (``TerminalInputDrain``) when woken.
/// It replaces an `AsyncStream` read by a detached task: a key no longer waits for a cooperative-pool
/// thread before the IO's own queue (Chromium's `ui::InputHandlerProxy` hands an event to the
/// compositor thread in one post, cc/input/input_handler.h; one hop here as there).
///
/// Producers: ``push(_:)`` from any thread. The main thread (keys, pastes, grid reports) writes the
/// single-producer ring; another thread (Ghostty's replies to queries on the output lane), or the
/// main thread while the ring is full or while records wait in the overflow, appends to the ordered
/// overflow under a lock held only for that append; the consumer holds it only to swap the overflow's
/// array out, O(1). Records from one thread drain in the order that thread pushed them; the consumer
/// takes the ring's records before the overflow's.
public nonisolated final class TerminalInputLane: Sendable {
    /// Records the ring holds before pushes spill to the overflow.
    public static let ringCapacity = 256
    /// Overflow bytes past which a pushed `.bytes` record is dropped (the IO stopped draining).
    public static let overflowByteLimit = 16 << 20
    /// Overflow records past which any pushed record is dropped. It bounds a producer's append under the
    /// overflow lock (an array growth moves at most this many records), so the main thread's wait for
    /// that lock is bounded too.
    public static let overflowRecordLimit = 1 << 15

    private let drain: TerminalInputDrain
    private let ring: TerminalInputRing
    private let overflowByteLimit: Int
    private let overflowRecordLimit: Int
    // Lock carve-out: held only to append one record (a producer that is not the main thread, or the main
    // thread while the ring is full or spilled; an array growth moves at most ``overflowRecordLimit``
    // records) or to swap the overflow's array out (the drain queue, O(1)), never across a call out; the
    // main thread's common path, a free ring, never waits (``TerminalInputRing/push(_:)``).
    // TerminalInputLaneTests measures the main thread's push while the consumer takes a large overflow.
    private let overflow = Mutex(TerminalInputOverflow(), rank: .terminalInputLaneOverflow)
    /// True while records wait in the overflow: the main thread appends there too, so it never passes them.
    private let overflowing = Atomic<Bool>(false)
    private let closed = Atomic<Bool>(false)
    private let dropped = Atomic<Int>(0)
    private let wake: any DispatchSourceUserDataAdd

    public init(drain: TerminalInputDrain, ringCapacity: Int = TerminalInputLane.ringCapacity,
                overflowByteLimit: Int = TerminalInputLane.overflowByteLimit,
                overflowRecordLimit: Int = TerminalInputLane.overflowRecordLimit) {
        self.drain = drain
        self.overflowByteLimit = overflowByteLimit
        self.overflowRecordLimit = overflowRecordLimit
        ring = TerminalInputRing(capacity: ringCapacity)
        wake = DispatchSource.makeUserDataAddSource(queue: drain.queue)
        // Strong: records pushed before ``close()`` still drain after their session is gone; the drain
        // cancels the source once the closed lane is empty, which releases this handler.
        wake.setEventHandler { [self] in drainRecords() }
        wake.activate()
    }

    /// Adds `record` after every record this thread pushed before, and wakes the drain. Never waits for
    /// the drain. Returns false when it dropped the record: the lane is closed, or the overflow holds
    /// ``overflowByteLimit`` bytes (a `.bytes` record) or ``overflowRecordLimit`` records.
    // perf-hot: 2us terminal-input-lane
    @discardableResult
    public func push(_ record: TerminalInputRecord) -> Bool {
        guard !closed.load(ordering: .acquiring) else { return false }
        if pthread_main_np() != 0, !overflowing.load(ordering: .acquiring), ring.push(record) {
            wake.add(data: 1)
            return true
        }
        let (byteLimit, recordLimit) = (overflowByteLimit, overflowRecordLimit)
        let kept = overflow.withLock { overflow -> Bool in
            guard overflow.append(record, byteLimit: byteLimit, recordLimit: recordLimit) else { return false }
            overflowing.store(true, ordering: .releasing)
            return true
        }
        guard kept else {
            dropped.add(1, ordering: .relaxed)
            return false
        }
        wake.add(data: 1)
        return true
    }

    /// Drops every later push. Records already pushed still drain; then the lane lets its drain go.
    public func close() {
        closed.store(true, ordering: .releasing)
        wake.add(data: 1)
    }

    /// Records dropped because the overflow was full (diagnostics, tests).
    public var droppedRecords: Int { dropped.load(ordering: .relaxed) }

    // MARK: Drain (the drain's queue)

    private func drainRecords() {
        // A record held by the handler keeps every later one until its resume.
        guard !ring.held.load(ordering: .acquiring) else { return }
        while let record = next() {
            // Before the handler: its resume may run on another thread before it returns.
            ring.held.store(true, ordering: .relaxed)
            switch drain.handle(record, TerminalInputResume(ring: ring, wake: wake)) {
            case .next: ring.held.store(false, ordering: .relaxed)
            case .hold: return
            }
        }
        if closed.load(ordering: .acquiring) { wake.cancel() }
    }

    /// The oldest record: the backlog's, then, while the overflow holds records, every ring record
    /// followed by the overflow's (moved to the backlog), otherwise the ring's.
    private func next() -> TerminalInputRecord? {
        if let record = ring.takeBacklog() { return record }
        guard overflowing.load(ordering: .acquiring) else { return ring.pop() }
        // The main thread pushes no ring record until `overflowing` is cleared below, so every ring
        // record now came before the overflow's. Only the swap runs under the overflow lock.
        ring.moveToBacklog()
        let later = overflow.withLock { overflow -> [TerminalInputRecord] in
            overflowing.store(false, ordering: .releasing)
            return overflow.take()
        }
        ring.appendToBacklog(later)
        return ring.takeBacklog()
    }
}

/// Records pushed while the ring was full or by a thread other than the main thread, in push order.
private nonisolated struct TerminalInputOverflow {
    var records: [TerminalInputRecord] = []
    var bytes = 0

    /// Appends `record`; false when the overflow holds `recordLimit` records, or `record` is `.bytes`
    /// that would pass `byteLimit`.
    mutating func append(_ record: TerminalInputRecord, byteLimit: Int, recordLimit: Int) -> Bool {
        guard records.count < recordLimit else { return false }
        switch record {
        case .bytes(let data), .keyBytes(let data, _):
            guard bytes + data.count <= byteLimit else { return false }
            bytes += data.count
        case .resize, .focusGained, .takeOverSize, .reconnect, .resync:
            break
        }
        records.append(record)
        return true
    }

    /// Moves the records out, O(1): their storage goes to the caller, the overflow starts empty.
    mutating func take() -> [TerminalInputRecord] {
        var taken: [TerminalInputRecord] = []
        Swift.swap(&taken, &records)
        bytes = 0
        return taken
    }
}
