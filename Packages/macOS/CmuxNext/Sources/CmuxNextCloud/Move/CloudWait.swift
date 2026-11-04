import CmuxNextCompat
public import CmuxNextWakeups

/// Bounded waits on main-actor state for the Cloud flows.
@MainActor
public struct CloudWait {
    public init() {}
    /// Whether `condition` holds within `limit`: an observation, bounded by a one-shot deadline.
    public static func holds(within limit: Duration, until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if condition() { return true }
        // concurrency-allow: the observation task exits on cancellation; this bounds a machine link's start
        return await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await observe(condition) }
            group.addTask {
                // wakeup-allow: one-shot deadline for a machine link to come up
                try? await Task.sleep(for: limit)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    /// How a start's wait spaces its redials (``holds(within:redialing:redial:until:)``): 1 s growing to 10 s, so a
    /// new machine's receiver that answers half a minute after its record runs is dialed again within seconds.
    public static let startRedial = Backoff(initial: .seconds(1), maximum: .seconds(10))

    /// Whether `condition` holds within `limit`: `redial` runs first and again after each of `backoff`'s delays,
    /// so a link that ended while the condition did not hold yet is dialed again (a new machine's daemon may
    /// answer a little after its record runs). Never past `limit`, and never without a delay between redials.
    public static func holds(within limit: Duration, redialing backoff: Backoff, redial: @MainActor () -> Void,
                             until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        var backoff = backoff
        // wakeup-allow: each pass waits one backoff delay (at least its initial's floor) and ends at the deadline
        while !Task.isCancelled {
            let left = clock.now.duration(to: deadline)
            guard left > .zero else { break }
            redial()
            if await holds(within: min(backoff.next(), left), until: condition) { return true }
        }
        // The deadline passed or the wait was cancelled: a change racing either is not this wait's answer.
        return false
    }

    /// Waits within `limit` for a link to come up: nil once `connected`, else `failure`, or `deadline`
    /// when there is none. A failure already showing when the wait begins is the last link's: it ends
    /// the wait only once the new connect cleared it and failed again, or at the deadline.
    public static func linkFailure(within limit: Duration, connected: @escaping @MainActor @Sendable () -> Bool,
                                   failure: @escaping @MainActor @Sendable () -> String?, deadline: String) async -> String? {
        @MainActor final class Seen { var cleared = false }
        let seen = Seen()
        seen.cleared = failure() == nil
        _ = await holds(within: limit) {
            if connected() { return true }
            guard failure() != nil else {
                seen.cleared = true
                return false
            }
            return seen.cleared
        }
        return connected() ? nil : failure() ?? deadline
    }

    private static func observe(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        for await ready in ObservationStream({ condition() }) where ready { return true }
        return false
    }
}
