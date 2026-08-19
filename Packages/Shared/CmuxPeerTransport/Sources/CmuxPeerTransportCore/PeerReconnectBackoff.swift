import Foundation

/// Seedable SplitMix64 so tests pin exact schedules.
public struct PeerBackoffRandomSource: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in [lower, upper] at millisecond resolution.
    public mutating func duration(in lower: Duration, _ upper: Duration) -> Duration {
        guard upper > lower else { return lower }
        let lowerMillis = lower.wholeMilliseconds
        let upperMillis = upper.wholeMilliseconds
        guard upperMillis > lowerMillis else { return lower }
        let span = UInt64(upperMillis - lowerMillis)
        let offset = next() % (span &+ 1)
        return .milliseconds(lowerMillis + Int64(offset))
    }
}

extension Duration {
    fileprivate var wholeMilliseconds: Int64 {
        components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}

/// Decorrelated-jitter reconnect backoff: each delay is drawn uniformly from
/// [floor, min(cap, previous * 3)]. One shared, injectable component instead
/// of per-call-site sleeps — the recorded failure mode was a phone re-running
/// broker work every 2-10s for 40+ hours (no ladder) alongside 32-36s naps on
/// single blips (host-profile ladder applied to the foreground client).
public struct PeerReconnectBackoff: Sendable {
    public struct Profile: Sendable {
        public let floor: Duration
        public let cap: Duration

        public init(floor: Duration, cap: Duration) {
            self.floor = floor
            self.cap = cap
        }

        /// Foreground client: fast first retry, bounded at 30s.
        public static let foregroundClient = Profile(floor: .seconds(1), cap: .seconds(30))
        /// Host / background daemon: slower ladder, bounded at 1h.
        public static let host = Profile(floor: .seconds(30), cap: .seconds(3600))
    }

    public let profile: Profile
    private var random: PeerBackoffRandomSource
    private var previous: Duration?
    private var serverFloor: Duration?

    public init(profile: Profile, seed: UInt64 = 0x5EED_C0DE) {
        self.profile = profile
        self.random = PeerBackoffRandomSource(seed: seed)
    }

    /// The next delay to wait before another attempt.
    public mutating func nextDelay() -> Duration {
        let upper: Duration
        if let previous {
            let tripled = previous * 3
            upper = min(profile.cap, tripled)
        } else {
            upper = profile.floor
        }
        var delay = random.duration(in: profile.floor, max(profile.floor, upper))
        if let serverFloor {
            // Retry-After is a bounded lower bound, never an unbounded wedge.
            delay = max(delay, min(serverFloor, profile.cap))
        }
        previous = delay
        return delay
    }

    /// Honor a server Retry-After for the next attempt only.
    public mutating func noteServerRetryAfter(_ floor: Duration) {
        serverFloor = max(serverFloor ?? .zero, floor)
    }

    /// Reset on success, scene-active, network path change, and account
    /// switch, so a single stale ladder cannot outlive the condition that
    /// armed it.
    public mutating func reset() {
        previous = nil
        serverFloor = nil
    }
}
