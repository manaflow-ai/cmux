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
    private var streams: [UInt64: Stream] = [:]
    private var nextArrival: UInt64 = 0
    private var reportedHalfFull = false

    private struct Stream {
        var events: [PageHeldEvent] = []
        var gap = false

        /// Trims to what `policy` keeps (oldest first out) and returns what it dropped.
        mutating func apply(_ policy: PageFrozenDelivery) -> [PageHeldEvent] {
            guard let keeps = policy.keeps, events.count > keeps else { return [] }
            let dropped = Array(events.prefix(events.count - keeps))
            events.removeFirst(events.count - keeps)
            if policy.dropMarksGap { gap = true }
            return dropped
        }
    }

    /// The events kept now, across streams.
    var count: Int { streams.values.reduce(0) { $0 + $1.events.count } }

    mutating func hold() {
        isHeld = true
    }

    /// Keeps one event of `sub`. A nil policy (the stream's `subscribe` still runs) keeps
    /// everything until ``apply(_:to:)``. Returns the events the policy dropped, and true the first
    /// time in this hold that an `.ordered` stream reaches ``PageFrozenDelivery/orderedHalfFull``.
    mutating func keep(sub: UInt64, _ data: JSONValue, publicationID: UInt64?,
                       policy: PageFrozenDelivery?) -> (dropped: [PageHeldEvent], halfFull: Bool) {
        // In place: a copy of the stream would copy its events on every append.
        streams[sub, default: Stream()].events.append(PageHeldEvent(arrival: nextArrival, data: data, publicationID: publicationID))
        nextArrival &+= 1
        var dropped: [PageHeldEvent] = []
        if let policy { dropped = streams[sub, default: Stream()].apply(policy) }
        let kept = streams[sub]?.events.count ?? 0
        guard policy == .ordered, !reportedHalfFull, kept >= PageFrozenDelivery.orderedHalfFull else {
            return (dropped, false)
        }
        reportedHalfFull = true
        return (dropped, true)
    }

    /// Applies the policy a stream named once its `subscribe` answered; returns what it dropped.
    mutating func apply(_ policy: PageFrozenDelivery, to sub: UInt64) -> [PageHeldEvent] {
        guard streams[sub] != nil else { return [] }
        return streams[sub, default: Stream()].apply(policy)
    }

    /// Forgets `sub`'s events (the page ended the stream).
    mutating func remove(_ sub: UInt64) {
        streams.removeValue(forKey: sub)
    }

    /// Ends the hold and returns what it kept in arrival order; the first event of a stream that
    /// dropped any carries the gap.
    mutating func release() -> [PageReleasedEvent] {
        isHeld = false
        reportedHalfFull = false
        var released: [PageReleasedEvent] = []
        released.reserveCapacity(count)
        for (sub, stream) in streams {
            for (index, event) in stream.events.enumerated() {
                released.append(PageReleasedEvent(sub: sub, event: event, gap: index == 0 && stream.gap))
            }
        }
        streams.removeAll()
        released.sort { $0.event.arrival < $1.event.arrival }
        return released
    }

    /// Empties the hold without ending it (the page's document went away), by subscription.
    mutating func drain() -> [(sub: UInt64, events: [PageHeldEvent])] {
        let drained = streams.sorted { $0.key < $1.key }.map { (sub: $0.key, events: $0.value.events) }
        streams.removeAll()
        return drained
    }
}
