import Foundation

/// Bounded backoff for attachment resolution. The Mac never concludes that a
/// terminal is missing from a slow or busy daemon; it retries on this schedule
/// and either succeeds or reports the last reason honestly.
public struct CloudTerminalAttachmentRetryPolicy: Equatable, Sendable {
    public let delays: [Duration]

    public init(delays: [Duration]) {
        precondition(!delays.isEmpty)
        precondition(delays.allSatisfy { $0 > .zero })
        self.delays = delays
    }

    /// One user-initiated open: a couple of quick retries, then a distinct
    /// "did not answer in time" error rather than "not created".
    public static let materialize = Self(delays: [.seconds(1), .seconds(2)])

    /// An already-open pane: keep trying at a bounded interval for as long as
    /// the pane exists, so recovery never depends on an external edge.
    public static let background = Self(delays: [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30),
    ])

    /// The wait before the next attempt after `failures` consecutive failures,
    /// or nil once the schedule is exhausted.
    public func boundedDelay(afterFailures failures: Int) -> Duration? {
        guard failures > 0, failures <= delays.count else { return nil }
        return delays[failures - 1]
    }

    /// The wait before the next attempt, holding the last delay forever.
    public func cappedDelay(afterFailures failures: Int) -> Duration {
        delays[min(max(failures, 1), delays.count) - 1]
    }
}
