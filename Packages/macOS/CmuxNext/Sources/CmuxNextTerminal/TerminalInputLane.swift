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
/// overflow under a lock held only for that append. Records from one thread drain in the order that
/// thread pushed them; the consumer takes the ring's records before the overflow's.
public nonisolated final class TerminalInputLane: Sendable {
    /// Records the ring holds before pushes spill to the overflow.
    public static let ringCapacity = 256
    /// Overflow bytes past which a pushed `.bytes` record is dropped (the IO stopped draining). Other
    /// records are always kept: they come at the rate of a person's clicks and focus changes.
    public static let overflowByteLimit = 16 << 20

    private let drain: TerminalInputDrain
    private let ring: TerminalInputRing
    private let overflowByteLimit: Int
    // Lock carve-out: held only to append one record (a producer that is not the main thread, or the main
    // thread while the ring is full or spilled) or to move the overflow into the backlog (the drain queue),
    // never across a call out; the main thread's common path, a free ring, never waits (``TerminalInputRing/push(_:)``).
    private let overflow = Mutex(TerminalInputOverflow())
    /// True while records wait in the overflow: the main thread appends there too, so it never passes them.
    private let overflowing = Atomic<Bool>(false)
    private let closed = Atomic<Bool>(false)
    private let dropped = Atomic<Int>(0)
    private let wake: any DispatchSourceUserDataAdd

    public init(drain: TerminalInputDrain, ringCapacity: Int = TerminalInputLane.ringCapacity,
                overflowByteLimit: Int = TerminalInputLane.overflowByteLimit) {
        self.drain = drain
        self.overflowByteLimit = overflowByteLimit
        ring = TerminalInputRing(capacity: ringCapacity)
        wake = DispatchSource.makeUserDataAddSource(queue: drain.queue)
        // Strong: records pushed before ``close()`` still drain after their session is gone; the drain
        // cancels the source once the closed lane is empty, which releases this handler.
        wake.setEventHandler { [self] in drainRecords() }
        wake.activate()
    }

    /// Adds `record` after every record this thread pushed before, and wakes the drain. Never waits for
    /// the drain. Returns false when it dropped the record: the lane is closed, or the overflow holds
    /// ``overflowByteLimit`` bytes.
    @discardableResult
    public func push(_ record: TerminalInputRecord) -> Bool {
        guard !closed.load(ordering: .acquiring) else { return false }
        if pthread_main_np() != 0, !overflowing.load(ordering: .acquiring), ring.push(record) {
            wake.add(data: 1)
            return true
        }
        let limit = overflowByteLimit
        let kept = overflow.withLock { overflow -> Bool in
            guard overflow.append(record, byteLimit: limit) else { return false }
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
    /// followed by the overflow's (moved to the backlog together), otherwise the ring's.
    private func next() -> TerminalInputRecord? {
        if let record = ring.takeBacklog() { return record }
        guard overflowing.load(ordering: .acquiring) else { return ring.pop() }
        overflow.withLock { overflow in
            // The main thread pushes no ring record while the overflow holds records, so every ring
            // record now came before them.
            ring.moveToBacklog(then: overflow.take())
            overflowing.store(false, ordering: .releasing)
        }
        return ring.takeBacklog()
    }
}

/// Records pushed while the ring was full or by a thread other than the main thread, in push order.
private nonisolated struct TerminalInputOverflow {
    var records: [TerminalInputRecord] = []
    var bytes = 0

    /// Appends `record`; false when it is `.bytes` that would pass `byteLimit`.
    mutating func append(_ record: TerminalInputRecord, byteLimit: Int) -> Bool {
        if case .bytes(let data) = record {
            guard bytes + data.count <= byteLimit else { return false }
            bytes += data.count
        }
        records.append(record)
        return true
    }

    mutating func take() -> [TerminalInputRecord] {
        defer {
            records = []
            bytes = 0
        }
        return records
    }
}
