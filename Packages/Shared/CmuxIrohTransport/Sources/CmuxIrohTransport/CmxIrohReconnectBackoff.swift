public import Foundation
import os

/// Bounds for one client-side reconnect retry ladder.
public struct CmxIrohReconnectBackoffConfiguration: Equatable, Sendable {
    /// The smallest delay the ladder can produce.
    public let floor: TimeInterval

    /// The largest locally scheduled delay. A server Retry-After directive
    /// may exceed it; the local schedule never does.
    public let cap: TimeInterval

    /// The decorrelated-jitter growth factor applied to the previous delay.
    public let multiplier: Double

    /// Creates normalized ladder bounds.
    public init(floor: TimeInterval, cap: TimeInterval, multiplier: Double) {
        let normalizedFloor = max(0.1, floor)
        self.floor = normalizedFloor
        self.cap = max(normalizedFloor, cap)
        self.multiplier = max(1, multiplier)
    }

    /// The interactive-client profile: a 1 second floor keeps recovery from a
    /// single blip immediate, and a 30 second cap guarantees a foregrounded
    /// app with a reachable network never naps for minutes between attempts.
    public static let foreground = Self(floor: 1, cap: 30, multiplier: 3)
}

/// Decorrelated-jitter retry backoff shared by the client reconnect ladders.
///
/// Each failure draws the next delay uniformly from
/// `[floor, min(cap, previous * multiplier)]`, so consecutive failures spread
/// out without synchronizing across devices. ``reset()`` returns the ladder to
/// its floor; owners call it on scenePhase-active transitions, on
/// network-path-change signals, and on success, so recovery after a real state
/// change is always immediate. A server Retry-After directive is honored as a
/// lower bound even beyond the local cap.
///
/// Deterministic by construction: delays come from a seedable SplitMix64
/// stream, so tests can assert an exact schedule from a fixed seed.
public final class CmxIrohReconnectBackoff: Sendable {
    private struct State {
        var previousDelay: TimeInterval?
        var rngState: UInt64
    }

    private let configuration: CmxIrohReconnectBackoffConfiguration
    private let state: OSAllocatedUnfairLock<State>

    /// Creates a ladder at its floor.
    ///
    /// - Parameters:
    ///   - configuration: The ladder bounds.
    ///   - seed: The jitter stream seed. Fixed seeds give exact schedules.
    public init(
        configuration: CmxIrohReconnectBackoffConfiguration = .foreground,
        seed: UInt64 = UInt64.random(in: .min ... .max)
    ) {
        self.configuration = configuration
        state = OSAllocatedUnfairLock(
            initialState: State(previousDelay: nil, rngState: seed)
        )
    }

    /// Returns the next retry delay after a failure.
    ///
    /// - Parameter retryAfterSeconds: A server-provided floor, when one exists.
    ///   It always wins over the local schedule, bounded only by
    ///   ``CmxIrohBrokerCooldown/maximumRetryAfterSeconds``.
    /// - Returns: A delay within `[floor, cap]`, or the larger server floor.
    public func nextDelay(retryAfterSeconds: Int? = nil) -> TimeInterval {
        let drawn = state.withLock { state in
            let previous = state.previousDelay ?? configuration.floor
            let upper = min(
                configuration.cap,
                max(configuration.floor, previous * configuration.multiplier)
            )
            let unit = Self.nextUnitRandom(&state.rngState)
            let delay = configuration.floor
                + (upper - configuration.floor) * unit
            state.previousDelay = delay
            return delay
        }
        guard let retryAfterSeconds else { return drawn }
        let serverFloor = TimeInterval(min(
            max(1, retryAfterSeconds),
            CmxIrohBrokerCooldown.maximumRetryAfterSeconds
        ))
        return max(drawn, serverFloor)
    }

    /// Returns the ladder to its floor. Owners call this on success, on
    /// scenePhase-active transitions, and on network-path-change signals.
    public func reset() {
        state.withLock { $0.previousDelay = nil }
    }

    /// SplitMix64: a tiny, well-distributed deterministic stream that turns a
    /// seed into uniform doubles in `[0, 1)`.
    private static func nextUnitRandom(_ rngState: inout UInt64) -> Double {
        rngState &+= 0x9E37_79B9_7F4A_7C15
        var mixed = rngState
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        return Double(mixed >> 11) * 0x1.0p-53
    }
}
