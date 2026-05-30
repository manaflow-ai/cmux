// SPDX-License-Identifier: MIT

import Foundation

/// Single-producer / multi-consumer-via-drain bounded ring of
/// ``OutputEvent`` tuples keyed by a monotonically increasing event
/// ``seq``. Drop-oldest on overflow; the next assigned seq is always
/// `lastAppendedSeq + 1` so a client that observes a JUMP in `id:`
/// values knows it dropped intermediate events (D6).
///
/// Locking: a single ``NSLock`` guards the storage. The lock is taken
/// only after the C tee trampoline has already memcpy'd the payload
/// into a stack-resident ``Data`` (see ``OutputTee`` in the app
/// target), so this lock is never held under ``renderer_state.mutex``.
public final class EventRing: @unchecked Sendable {
    /// Maximum number of events retained in the ring before the oldest
    /// entry is overwritten by the next ``append(_:)``.
    public let capacity: Int

    private let lock = NSLock()
    private var buffer: [(seq: UInt64, event: OutputEvent)] = []
    private var lastSeq: UInt64 = 0

    /// Creates an empty ring with the given event-count capacity.
    ///
    /// - Parameter capacity: Maximum number of events retained; must be
    ///   positive.
    public init(capacity: Int) {
        precondition(capacity > 0, "EventRing capacity must be positive")
        self.capacity = capacity
        self.buffer.reserveCapacity(capacity)
    }

    /// Highest seq ever appended (including dropped entries).
    public var lastAppendedSeq: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return lastSeq
    }

    /// Seq of the oldest entry currently in the ring (0 if empty).
    public var oldestSeq: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return buffer.first?.seq ?? 0
    }

    /// Drop-oldest append. Returns the seq assigned to this event.
    ///
    /// - Parameter event: Event payload; the embedded ``seq`` is ignored
    ///   and replaced with the next monotonic value.
    /// - Returns: The seq assigned to the appended event.
    @discardableResult
    public func append(_ event: OutputEvent) -> UInt64 {
        lock.lock()
        lastSeq &+= 1
        let s = lastSeq
        // Strip the caller's seq field by rebuilding with the
        // assigned monotonic seq.
        let normalized: OutputEvent
        switch event {
        case .rawBytes(let d, _):       normalized = .rawBytes(d, seq: s)
        case .cellsSnapshot(let g, _):  normalized = .cellsSnapshot(g, seq: s)
        case .gap:                       normalized = .gap(seq: s)
        }
        buffer.append((s, normalized))
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()
        return s
    }

    /// Drain all entries with seq > `after`. Returns ordered (seq, event)
    /// tuples. If `after` is below the ring's oldest seq, the caller
    /// should emit a synthetic gap before consuming the returned slice.
    ///
    /// - Parameter after: Last seq the caller has already observed.
    public func drain(after: UInt64) -> [(UInt64, OutputEvent)] {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        var idx = 0
        while idx < buffer.count && buffer[idx].seq <= after { idx += 1 }
        return Array(buffer[idx...])
    }

    /// Snapshot helper: true if `after` is too old to resume from
    /// in-ring (i.e., resume must emit a synthetic gap).
    ///
    /// - Parameter after: Last seq the caller has already observed.
    public func resumeIsBelowOldest(_ after: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let first = buffer.first else { return after < lastSeq }
        return after < first.seq
    }
}
