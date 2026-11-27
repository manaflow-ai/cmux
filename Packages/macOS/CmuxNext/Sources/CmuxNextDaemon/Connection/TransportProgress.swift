import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// When a ``LineTransport`` last moved bytes for its requests: a slice of a queued request written to
/// the socket, or bytes read toward a line not finished yet (a reply on its way). A request's deadline
/// is silence since then, not time since it was sent, so a reply that is still arriving is never cut
/// off (Leo, 2026-11-24: "10s timeout for messages being sendsble is a shame. if it's making good
/// progress, it shiukd be allowed to keep going?"). A 10 MiB terminal replay over a slow link, a prompt
/// with a large image, an attachment chunk: each keeps going while its bytes move.
///
/// Progress is the connection's, not one request's: the daemon starts commands serially per connection
/// and writes one line at a time, so a reply waiting behind another line that is still arriving waits on
/// exactly that progress. A connection that moves no byte for the whole bound still fails its requests.
nonisolated final class TransportProgress: Sendable {
    private let last: Mutex<ContinuousClock.Instant>

    init(now: ContinuousClock.Instant = .now) { last = Mutex(now) }

    /// Records progress now.
    func note(at now: ContinuousClock.Instant = .now) {
        last.withLock { if now > $0 { $0 = now } }
    }

    /// The latest progress.
    var lastAt: ContinuousClock.Instant { last.withLock { $0 } }

    /// How long a request armed at `armedAt` may still wait, with `quiet` as its silence bound: nil once
    /// nothing moved for `quiet` (neither since it was armed nor since the latest progress).
    static func remaining(quiet: Duration, armedAt: ContinuousClock.Instant, lastProgress: ContinuousClock.Instant,
                          now: ContinuousClock.Instant) -> Duration? {
        let since = max(armedAt, lastProgress)
        let left = quiet - (now - since)
        return left > .zero ? left : nil
    }

    /// Arms `timer` to call `onQuiet` once nothing moved for `quiet` since `armedAt`. Each fire that finds
    /// newer progress arms the rest of the bound again, so the timer wakes at most once per `quiet` of
    /// progress, never per byte.
    func arm(_ timer: DemandTimer, quiet: Duration, armedAt: ContinuousClock.Instant = .now,
             onQuiet: @escaping @Sendable () -> Void) {
        arm(timer, quiet: quiet, armedAt: armedAt, after: quiet, onQuiet: onQuiet)
    }

    private func arm(_ timer: DemandTimer, quiet: Duration, armedAt: ContinuousClock.Instant, after delay: Duration,
                     onQuiet: @escaping @Sendable () -> Void) {
        timer.schedule(after: delay) { [weak self] in
            guard let self else { return onQuiet() }
            if let left = Self.remaining(quiet: quiet, armedAt: armedAt, lastProgress: self.lastAt, now: .now) {
                self.arm(timer, quiet: quiet, armedAt: armedAt, after: left, onQuiet: onQuiet)
            } else {
                onQuiet()
            }
        }
    }
}
