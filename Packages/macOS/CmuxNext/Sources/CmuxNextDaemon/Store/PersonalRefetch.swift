/// Where the store stands with `personal-changed` (`DaemonStore.refetchPersonal`): which personal
/// changes the store does not hold yet, and how far the applied sequence may move meanwhile.
///
/// A `personal-changed` event is applied by refetching `list-personal` alone. Until that reply
/// lands, the applied sequence stays below the first personal change it has not applied, so a
/// read-your-writes waiter (`whenApplied`) for a personal command never runs on the old state.
/// Events after it still apply at once; the sequence catches up when the refetch lands.
struct PersonalRefetch {
    /// The highest `personal-changed` sequence seen.
    private(set) var seen: UInt64 = 0
    /// The lowest `personal-changed` sequence the store does not hold yet; nil when it holds all.
    private(set) var pending: UInt64?
    /// The highest sequence otherwise applied, held back while `pending` is set.
    private(set) var held: UInt64 = 0
    /// A `list-personal` is in flight.
    var inFlight = false
    /// Another personal change came during the fetch: one more fetch follows it.
    var again = false

    /// A `personal-changed` at `sequence` was received.
    mutating func saw(_ sequence: UInt64) {
        seen = max(seen, sequence)
        if pending.map({ sequence < $0 }) ?? true { pending = sequence }
    }

    /// The sequence the store may report applied after a batch up to `last`.
    mutating func reachable(applying last: UInt64) -> UInt64 {
        held = max(held, last)
        guard let pending else { return last }
        return min(last, pending &- 1)
    }

    /// The `list-personal` asked for when `seen` was `covering` landed: the sequence the store may report now.
    mutating func landed(covering: UInt64) -> UInt64 {
        if seen <= covering {
            pending = nil
            return held
        }
        // A newer change came during the fetch: its own fetch follows.
        pending = covering &+ 1
        return min(held, covering)
    }

    /// A snapshot applied up to `barrier` holds every personal change at or below it.
    mutating func covered(through barrier: UInt64) {
        held = max(held, barrier)
        if seen <= barrier { pending = nil } else if let current = pending, current <= barrier { pending = barrier &+ 1 }
    }
}
