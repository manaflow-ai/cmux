import Foundation

/// Paces presence-triggered device-registry refreshes.
///
/// A signing-out Mac's clean `goodbye` and a signing-in Mac's `online`
/// transition both mean the durable registry membership may have changed, but
/// goodbyes also fire on plain app quits and a flapping network can deliver a
/// whole team's online transitions in one burst. Every triggered
/// ``MobileShellComposite/loadRegistryDevices()`` is a full `/api/devices`
/// round trip, so fetch STARTS are spaced at least ``minimumFetchInterval``
/// apart; the composite's single-flight refresh task coalesces all triggers
/// landing inside one window into a single trailing fetch.
struct MobilePresenceRegistryRefreshThrottle {
    /// Above any realistic same-team sign-out/sign-in burst cadence, low
    /// enough that a Mac leaving or joining the tree still reads as live.
    static let minimumFetchInterval: TimeInterval = 5

    private var lastFetchStartedAt: Date?

    /// Seconds to wait before the next fetch may start: 0 when no fetch has
    /// started yet or the interval already elapsed.
    func delayBeforeNextFetch(now: Date) -> TimeInterval {
        guard let lastFetchStartedAt else { return 0 }
        let elapsed = now.timeIntervalSince(lastFetchStartedAt)
        // A rewound wall clock (negative elapsed) must not freeze refreshes
        // until the clock catches back up; treat it as expired (mirrors
        // MobilePresencePushRecoveryThrottle).
        guard elapsed >= 0, elapsed < Self.minimumFetchInterval else { return 0 }
        return Self.minimumFetchInterval - elapsed
    }

    /// Records a fetch start; the next window is measured from here, not from
    /// fetch completion, so a slow registry cannot stretch the cadence.
    mutating func noteFetchStarted(now: Date) {
        lastFetchStartedAt = now
    }

    /// Forgets pacing history at an account or team boundary so the next
    /// scope's first trigger fetches immediately.
    mutating func reset() {
        lastFetchStartedAt = nil
    }
}
