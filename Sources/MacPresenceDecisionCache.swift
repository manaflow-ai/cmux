import Foundation

/// Bounds live presence sampling under notification bursts while the user is
/// AT the Mac (the suppression path, which deliberately never consumes a
/// send-throttle slot in `PhonePushClient.forward`).
///
/// Invariant, chosen explicitly: any bounded-work design serves a decision up
/// to ``ttl`` stale on one side of an active/away transition. The staleness
/// goes on the SUPPRESSION side only:
///
/// - ACTIVE decisions are reused for up to ``ttl``. A burst while the user is
///   at the Mac samples WindowServer/AppKit/HID at most once per TTL instead
///   of per notification. This is the typing-adjacent main-actor hot path the
///   send throttle cannot protect, because suppressed notifications must not
///   consume send slots.
/// - AWAY decisions are NEVER reused. A forwarding decision is always fresh,
///   so a stale away answer can never leak a push to the phone after the
///   user has returned to the Mac.
///
/// Cost of the chosen staleness: a notification arriving within ``ttl`` after
/// the user locks/leaves can be suppressed once. The user was provably at the
/// Mac within the last second (hardware input, unlocked screen) and saw the
/// notification there; suppressed pushes are never retroactively sent by
/// design, and the next notification more than ``ttl`` later re-samples
/// fresh.
struct MacPresenceDecisionCache {
    static let ttl: TimeInterval = 1.0

    private var last: MacPresenceMonitor.Decision?

    mutating func decision(from monitor: MacPresenceMonitor) -> MacPresenceMonitor.Decision {
        let now = monitor.now()
        if let last,
           last.isActive,
           now >= last.evaluatedAt,
           now.timeIntervalSince(last.evaluatedAt) < Self.ttl {
            return last
        }
        let fresh = monitor.evaluate()
        last = fresh
        return fresh
    }
}
