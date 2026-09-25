import Foundation

/// Bounded recovery for the event side channel. The command socket remains usable while the
/// feed is repaired, but a broken child process must never create an infinite spawn loop.
public struct CloudMachineLinkEventsRecoveryPolicy: Sendable, Equatable {
    public static let standard = Self(delays: [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(4),
    ], stabilityWindow: .seconds(10))

    public let delays: [Duration]
    /// A stream must carry an accepted event for this long before prior failures
    /// stop counting. This prevents a child that emits one event and exits from
    /// resetting the bounded recovery budget forever.
    public let stabilityWindow: Duration

    public init(delays: [Duration], stabilityWindow: Duration = .seconds(10)) {
        precondition(!delays.isEmpty)
        precondition(delays.allSatisfy { $0 > .zero })
        precondition(stabilityWindow > .zero)
        self.delays = delays
        self.stabilityWindow = stabilityWindow
    }

    public func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt > 0, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

