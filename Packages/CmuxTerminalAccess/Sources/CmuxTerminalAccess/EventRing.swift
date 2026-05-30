// SPDX-License-Identifier: MIT

import Foundation

/// Single-producer / multi-consumer-via-drain bounded ring of
/// ``OutputEvent`` tuples keyed by a monotonically increasing event
/// ``seq``. Drop-oldest on overflow; next ``seq`` is monotonic so the
/// client sees a JUMP in id values when bytes were dropped (D6).
///
/// Stub: behavior implemented in Task 2.6.
public final class EventRing: @unchecked Sendable {
    /// Maximum number of events retained in the ring before the oldest
    /// entry is overwritten by the next ``append(_:)``.
    public let capacity: Int

    /// Creates an empty ring with the given event-count capacity.
    ///
    /// - Parameter capacity: Maximum number of events retained; must be
    ///   positive.
    public init(capacity: Int) { self.capacity = capacity }

    /// Highest seq ever appended (including dropped entries).
    public var lastAppendedSeq: UInt64 { 0 }

    /// Seq of the oldest entry currently in the ring (0 if empty).
    public var oldestSeq: UInt64 { 0 }

    /// Drop-oldest append. Returns the seq assigned to this event.
    ///
    /// - Parameter event: Event payload; the embedded ``seq`` is ignored
    ///   and replaced with the next monotonic value.
    /// - Returns: The seq assigned to the appended event.
    @discardableResult
    public func append(_ event: OutputEvent) -> UInt64 { 0 }

    /// Drain all entries with seq > `after`. Returns ordered (seq, event)
    /// tuples. If `after` is below the ring's oldest seq, the caller
    /// should emit a synthetic gap before consuming the returned slice.
    ///
    /// - Parameter after: Last seq the caller has already observed.
    public func drain(after: UInt64) -> [(UInt64, OutputEvent)] { [] }

    /// Snapshot helper: true if `after` is too old to resume from
    /// in-ring (i.e., resume must emit a synthetic gap).
    ///
    /// - Parameter after: Last seq the caller has already observed.
    public func resumeIsBelowOldest(_ after: UInt64) -> Bool { false }
}
