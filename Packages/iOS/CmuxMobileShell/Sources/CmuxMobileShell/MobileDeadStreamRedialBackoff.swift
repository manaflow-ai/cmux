import Foundation

/// Backoff for redialing after a terminal event subscription ends — or is
/// rejected — before it ever delivered an event.
///
/// A healthy reconnect delivers events, which proves the transport carries
/// traffic and clears the streak. A subscription that keeps ending "barren"
/// (no event delivered) is a broken push path; redialing it again immediately
/// only restarts the same failing stream, so the redial → restart → re-end
/// cycle spins at scheduler speed. On iOS that pinned the main thread at ~94%
/// CPU after foregrounding, froze scrolling, and burned cellular data on
/// repeated full replays (https://github.com/manaflow-ai/cmux/issues/10482).
///
/// The first barren stream still recovers immediately — a genuine transient
/// blip should heal fast — while each subsequent barren stream backs off
/// exponentially so the loop cannot spin.
struct MobileDeadStreamRedialBackoff {
    static let initialBackoff: Duration = .seconds(1)
    static let maximumBackoff: Duration = .seconds(30)

    private(set) var consecutiveBarrenRedials = 0
    private var nextBackoff = MobileDeadStreamRedialBackoff.initialBackoff
    private(set) var isRedialScheduled = false

    /// The delay to wait before redialing after a stream ended barren. Returns
    /// `.zero` for the first barren stream (recover immediately), an increasing
    /// delay for each subsequent one, or `nil` when a delayed redial is already
    /// scheduled — so simultaneous barren signals coalesce onto one timer
    /// instead of stacking redials.
    mutating func nextRedialDelay() -> Duration? {
        guard !isRedialScheduled else { return nil }
        consecutiveBarrenRedials += 1
        guard consecutiveBarrenRedials > 1 else { return .zero }
        let delay = nextBackoff
        nextBackoff = min(nextBackoff * 2, Self.maximumBackoff)
        isRedialScheduled = true
        return delay
    }

    /// A scheduled delayed redial fired; allow the next barren stream to
    /// schedule again.
    mutating func redialFired() {
        isRedialScheduled = false
    }

    /// A delivered event (or an intentional teardown / foreground reset) proves
    /// the connection is healthy again; clear the barren streak so the next
    /// failure recovers fast.
    mutating func reset() {
        consecutiveBarrenRedials = 0
        nextBackoff = Self.initialBackoff
        isRedialScheduled = false
    }
}
