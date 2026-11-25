import Foundation

/// Which spare warms go to Rust (hq#8747 ask 4). The app warms on every activation, and each warm
/// spawns `cmux link start-chat warm-spare` before Rust's throttle answers, so a Cmd-Tab burst
/// spawned a burst of processes that Rust then answered "throttled". One warm per person runs at a
/// time, and none starts within ``gap`` of the last one: Rust would only replay that one's answer.
@MainActor public final class CloudSpareWarmGate {
    /// Rust's shortest gap between two warms of one person (`NONE_GAP_MS` in `spare_warm.rs`; a warm
    /// spare's is 120 s): a warm asked sooner gets the earlier answer replayed.
    public static let gap: Duration = .seconds(10)

    private var running: Set<String> = []
    private var started: [String: ContinuousClock.Instant] = [:]
    private let now: @MainActor () -> ContinuousClock.Instant
    /// Warms not started (tests, measurement).
    public private(set) var skipped = 0

    public init(now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// True when `account`'s warm may start now; it then counts as running until ``ended(_:)``.
    public func admit(_ account: String) -> Bool {
        let at = now()
        if running.contains(account) || started[account].map({ at - $0 < Self.gap }) == true {
            skipped += 1
            return false
        }
        running.insert(account)
        started[account] = at
        return true
    }

    /// `account`'s warm ended (answered, refused, or never asked).
    public func ended(_ account: String) {
        running.remove(account)
    }
}
