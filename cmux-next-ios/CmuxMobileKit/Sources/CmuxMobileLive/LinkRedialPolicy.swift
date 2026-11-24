#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif
import Foundation

/// The link's redial policy, decided in Rust (`cmux_mobile_link::reconnect::policy`, over
/// `cmux-mobile-link-ffi`'s `link_redial_*`): which attempt the next dial is, how long it waits,
/// when a lost link starts the backoff over (it stayed up ``stableAfter``), and when the machine
/// stops dialing on its own and offers Retry (past ``maxAttempts``).
///
/// Leo, 2026-11-24 (the endless reattach): a link that connected and then dropped, or failed
/// its first probe, redialed at attempt 1 each time, so the backoff never grew and "Reconnecting"
/// never became Retry. Now a drop of a link that was up less than ``stableAfter`` counts as a
/// failed attempt (acpmux `peer_link.rs` `Link::down`).
public enum LinkRedialPolicy {
    /// What the machine does after a failed dial or a lost link.
    public enum Redial: Equatable, Sendable {
        /// Dial again now, as `attempt`.
        case now(attempt: Int)
        /// Wait `after`, then dial `attempt + 1`.
        case wait(attempt: Int, after: Duration)
        /// No more dials on its own: waiting at `attempt` with nothing scheduled.
        case stop(attempt: Int)
    }

    /// A link up this long before it dropped starts over at attempt 1.
    public static var stableAfter: Duration { .milliseconds(Int64(clamping: limits.stableAfterMs)) }
    /// Attempts after a lost link that still read "Reconnecting"; later ones offer Retry.
    public static var reconnectingAttempts: Int { Int(limits.reconnectingAttempts) }
    /// The last attempt dialed without the person.
    public static var maxAttempts: Int { Int(limits.maxAttempts) }

    /// After dial `attempt` failed.
    public static func afterFailure(backoff: [Int], attempt: Int) -> Redial {
        #if canImport(CmuxMobileLinkFFI)
        Redial(linkRedialAfterFailure(backoffMs: millis(backoff), attempt: UInt32(clamping: attempt)))
        #else
        Fallback.afterFailure(backoff: backoff, attempt: attempt)
        #endif
    }

    /// After the link dial `connectedAttempt` made was lost `upFor` after it connected (nil: no
    /// clock, counted as stable).
    public static func afterDrop(backoff: [Int], connectedAttempt: Int, upFor: Duration?) -> Redial {
        #if canImport(CmuxMobileLinkFFI)
        Redial(linkRedialAfterDrop(backoffMs: millis(backoff), connectedAttempt: UInt32(clamping: connectedAttempt),
                                   upForMs: upFor.map(wholeMillis)))
        #else
        Fallback.afterDrop(backoff: backoff, connectedAttempt: connectedAttempt, upFor: upFor)
        #endif
    }

    /// The attempt of a dial restarted from `attempt` (news of a new path, Retry, a surface
    /// opening, the foreground): one more, never past ``maxAttempts``.
    public static func nextAttempt(after attempt: Int) -> Int {
        #if canImport(CmuxMobileLinkFFI)
        Int(linkRedialNextAttempt(attempt: UInt32(clamping: attempt)))
        #else
        min(attempt + 1, maxAttempts)
        #endif
    }

    /// The attempt of a dial news starts from a wait at `attempt` (the foreground, a new network
    /// path, the Mac's presence): a stopped redial starts over at 1, so stopping never strands
    /// the person; otherwise one more.
    public static func newsAttempt(after attempt: Int) -> Int {
        #if canImport(CmuxMobileLinkFFI)
        Int(linkRedialNewsAttempt(attempt: UInt32(clamping: attempt)))
        #else
        attempt >= maxAttempts ? 1 : nextAttempt(after: attempt)
        #endif
    }

    /// The policy's bounds, read from Rust once.
    struct Limits: Sendable {
        var stableAfterMs: UInt64
        var reconnectingAttempts: UInt32
        var maxAttempts: UInt32
    }

    static let limits: Limits = {
        #if canImport(CmuxMobileLinkFFI)
        let limits = linkRedialLimits()
        return Limits(stableAfterMs: limits.stableAfterMs, reconnectingAttempts: limits.reconnectingAttempts,
                      maxAttempts: limits.maxAttempts)
        #else
        // No Rust core (macOS package tests): `reconnect/policy.rs`'s values.
        return Limits(stableAfterMs: 60_000, reconnectingAttempts: 6, maxAttempts: 12)
        #endif
    }()

    #if canImport(CmuxMobileLinkFFI)
    private static func wholeMillis(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: max(seconds * 1000 + attoseconds / 1_000_000_000_000_000, 0))
    }

    private static func millis(_ backoff: [Int]) -> [UInt64] {
        backoff.map { UInt64(clamping: $0) * 1000 }
    }
    #endif
}

#if canImport(CmuxMobileLinkFFI)
extension LinkRedialPolicy.Redial {
    init(_ redial: LinkRedial) {
        switch redial {
        case .now(let attempt): self = .now(attempt: Int(attempt))
        case .wait(let attempt, let afterMs): self = .wait(attempt: Int(attempt), after: .milliseconds(Int64(clamping: afterMs)))
        case .stop(let attempt): self = .stop(attempt: Int(attempt))
        }
    }
}
#else
/// No Rust core (macOS package tests): the same rules as `reconnect/policy.rs`, checked against it
/// by the iOS simulator run of the same tests, which calls the Rust one.
private enum Fallback {
    static var limits: LinkRedialPolicy.Limits { LinkRedialPolicy.limits }

    static func delay(_ backoff: [Int], _ attempt: Int) -> Duration {
        guard let last = backoff.last else { return .zero }
        let index = max(attempt - 1 - LinkMachine.silentRetries, 0)
        return .seconds(index < backoff.count ? backoff[index] : last)
    }

    static func afterFailure(backoff: [Int], attempt: Int) -> LinkRedialPolicy.Redial {
        let attempt = max(attempt, 1)
        if attempt <= LinkMachine.silentRetries { return .now(attempt: attempt + 1) }
        if attempt >= Int(limits.maxAttempts) { return .stop(attempt: attempt) }
        return .wait(attempt: attempt, after: delay(backoff, attempt))
    }

    static func afterDrop(backoff: [Int], connectedAttempt: Int, upFor: Duration?) -> LinkRedialPolicy.Redial {
        guard let upFor, upFor < .milliseconds(Int64(limits.stableAfterMs)) else { return .now(attempt: 1) }
        return afterFailure(backoff: backoff, attempt: connectedAttempt)
    }
}
#endif
