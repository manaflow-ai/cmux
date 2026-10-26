import CmuxNextSettings

/// One event ``PageRouter`` keeps while delivery is held; `arrival` orders events across streams.
struct PageHeldEvent {
    let arrival: UInt64
    let data: JSONValue
    let publicationID: UInt64?
}

/// One event the hold sends at release, with whether it opens a gap (its stream dropped events).
struct PageReleasedEvent {
    let sub: UInt64
    let event: PageHeldEvent
    let gap: Bool
}

/// The events ``PageRouter`` keeps while the page is hidden or frozen, per subscription, by each
/// stream's ``PageFrozenDelivery``. A value type with no clock and no page: the router asks it what
/// to keep, what dropped and what to send.
struct PageDeliveryHold {
    private(set) var isHeld = false
    /// The events kept now, across streams.
    private(set) var count = 0
    private var streams: [UInt64: Stream] = [:]
    private var nextArrival: UInt64 = 0

    /// One stream's kept events. A drop advances `head` (O(1)); the dropped prefix is compacted
    /// once it is half the buffer, so a full `.queue(limit)` costs amortized O(1) per event.
    private struct Stream {
        private var storage: [PageHeldEvent] = []
        private var head = 0
        private(set) var gap = false

        var count: Int { storage.count - head }
        var events: ArraySlice<PageHeldEvent> { storage[head...] }

        mutating func append(_ event: PageHeldEvent) {
            storage.append(event)
        }

        /// Trims to what `policy` keeps (oldest first out) and returns what it dropped.
        mutating func apply(_ policy: PageFrozenDelivery) -> [PageHeldEvent] {
            guard let keeps = policy.keeps, count > keeps else { return [] }
            let end = storage.count - keeps
            // A copy, not a slice: a slice would share `storage` and make the next append copy it.
            let dropped = Array(storage[head..<end])
            head = end
            if policy.dropMarksGap { gap = true }
            if head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
            return dropped
        }
    }

    mutating func hold() {
        isHeld = true
    }

    /// Keeps one event of `sub`. A nil policy (the stream's `subscribe` still runs) keeps
    /// everything until ``apply(_:to:)``. Returns the events the policy dropped, and whether the
    /// stream is `.ordered` and now keeps ``PageFrozenDelivery/orderedHalfFull`` events (the router
    /// then sends the hold, ``flush()``).
    mutating func keep(sub: UInt64, _ data: JSONValue, publicationID: UInt64?,
                       policy: PageFrozenDelivery?) -> (dropped: [PageHeldEvent], halfFull: Bool) {
        // In place: a copy of the stream would copy its events on every append.
        streams[sub, default: Stream()].append(PageHeldEvent(arrival: nextArrival, data: data, publicationID: publicationID))
        nextArrival &+= 1
        count += 1
        guard let policy else { return ([], false) }
        let dropped = streams[sub, default: Stream()].apply(policy)
        count -= dropped.count
        let halfFull = policy == .ordered && (streams[sub]?.count ?? 0) >= PageFrozenDelivery.orderedHalfFull
        return (dropped, halfFull)
    }

    /// Applies the policy a stream named once its `subscribe` answered; returns what it dropped.
    mutating func apply(_ policy: PageFrozenDelivery, to sub: UInt64) -> [PageHeldEvent] {
        guard streams[sub] != nil else { return [] }
        let dropped = streams[sub, default: Stream()].apply(policy)
        count -= dropped.count
        return dropped
    }

    /// Forgets `sub`'s events (the page ended the stream).
    mutating func remove(_ sub: UInt64) {
        count -= streams.removeValue(forKey: sub)?.count ?? 0
    }

    /// Returns what the hold kept in arrival order and keeps holding; the first event of a stream
    /// that dropped any carries the gap.
    mutating func flush() -> [PageReleasedEvent] {
        var released: [PageReleasedEvent] = []
        released.reserveCapacity(count)
        for (sub, stream) in streams {
            for (index, event) in stream.events.enumerated() {
                released.append(PageReleasedEvent(sub: sub, event: event, gap: index == 0 && stream.gap))
            }
        }
        streams.removeAll()
        count = 0
        released.sort { $0.event.arrival < $1.event.arrival }
        return released
    }

    /// Ends the hold and returns what it kept, as ``flush()``.
    mutating func release() -> [PageReleasedEvent] {
        isHeld = false
        return flush()
    }

    /// Empties the hold without ending it (the page's document went away), by subscription.
    mutating func drain() -> [(sub: UInt64, events: [PageHeldEvent])] {
        let drained = streams.sorted { $0.key < $1.key }.map { (sub: $0.key, events: Array($0.value.events)) }
        streams.removeAll()
        count = 0
        return drained
    }
}
