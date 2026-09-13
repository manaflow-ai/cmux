import Foundation

/// Backoff used while a daemon is still executing a correlated creation.
///
/// This is an explicit progress wait, rather than a settling delay: the loop
/// ends only at a durable creation state or caller cancellation.
struct CloudTuiCreationRecoveryPolicy: Equatable, Sendable {
    let delays: [Duration]

    init(delays: [Duration]) {
        precondition(!delays.isEmpty)
        precondition(delays.allSatisfy { $0 > .zero })
        self.delays = delays
    }

    static let standard = Self(delays: [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30),
    ])

    func delay(afterAttempts attempts: Int) -> Duration {
        delays[min(max(attempts, 1), delays.count) - 1]
    }

    /// A pending receipt is progress, but it cannot hold an operation forever.
    /// The extra attempts cover a normal reconnect without making a permanently
    /// lost daemon response an unbounded task.
    var maximumResolutionAttempts: Int { delays.count + 2 }
}
