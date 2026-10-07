/// Smoothed RTT and retransmission timeout (RFC 6298) for one transport,
/// with exponential backoff while timeouts repeat.
struct RetransmitTimer {
    let minimum: Duration
    let maximum: Duration
    private(set) var smoothed: Duration?
    private var variation: Duration = .zero
    private var backoff = 1

    init(minimum: Duration, maximum: Duration) {
        self.minimum = minimum
        self.maximum = maximum
    }

    var timeout: Duration {
        let base = smoothed.map { $0 + max(.milliseconds(1), variation * 4) } ?? .milliseconds(200)
        return min(maximum, max(minimum, base) * backoff)
    }

    /// A sample from a fragment sent exactly once (Karn's rule).
    mutating func sample(_ rtt: Duration) {
        if let smoothed {
            let error = smoothed > rtt ? smoothed - rtt : rtt - smoothed
            variation = variation * 3 / 4 + error / 4
            self.smoothed = smoothed * 7 / 8 + rtt / 8
        } else {
            smoothed = rtt
            variation = rtt / 2
        }
        backoff = 1
    }

    mutating func timedOut() {
        backoff = min(backoff * 2, 64)
    }
}
