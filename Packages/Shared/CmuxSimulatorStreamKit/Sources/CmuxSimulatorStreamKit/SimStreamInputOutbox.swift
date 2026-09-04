/// Viewer-side input staging with loss-free semantics.
///
/// Every event is enqueued; the only transformation is that an unsent
/// `.moved` touch event is replaced in place by a newer `.moved` for the
/// same pointer. Down, up, cancel, key, text, and button events are never
/// coalesced, reordered, or dropped, so a fast drag cannot backlog the lane
/// and a tap can never lose its up half.
public struct SimStreamInputOutbox: Sendable, Equatable {
    private var pending: [SimStreamInputEvent] = []
    private var nextSequence: UInt64 = 1

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }
    public var pendingCount: Int { pending.count }

    public mutating func enqueue(_ event: SimStreamInputEvent) {
        if case .touch(let phase, let pointerID, _, _, _) = event, phase == .moved {
            // Walk backward only past other pointers' moves; stop at any
            // non-move event so ordering across phases is preserved.
            var index = pending.count - 1
            while index >= 0 {
                guard case .touch(let existingPhase, let existingPointer, _, _, _) =
                    pending[index], existingPhase == .moved
                else { break }
                if existingPointer == pointerID {
                    pending[index] = event
                    return
                }
                index -= 1
            }
        }
        pending.append(event)
    }

    /// Drains up to `limit` pending events into a wire batch.
    public mutating func drainBatch(limit: Int = 64) -> SimStreamInputBatch? {
        guard !pending.isEmpty else { return nil }
        let events = Array(pending.prefix(limit))
        pending.removeFirst(events.count)
        defer { nextSequence += 1 }
        return SimStreamInputBatch(sequence: nextSequence, events: events)
    }

    /// Discards pending events (stream teardown). The sequence keeps
    /// growing so the host's regression check stays valid across restarts
    /// on the same lane.
    public mutating func removeAll() {
        pending.removeAll()
    }
}

/// Host-side ordering guard for input batches: accepts each batch at most
/// once and only in increasing sequence order.
public struct SimStreamInputSequenceGuard: Sendable, Equatable {
    private var highestApplied: UInt64 = 0

    public init() {}

    public mutating func shouldApply(_ batch: SimStreamInputBatch) -> Bool {
        guard batch.sequence > highestApplied else { return false }
        highestApplied = batch.sequence
        return true
    }
}
