import Foundation

/// Supplies wall-clock time to activity retention code.
public protocol AgentActivityClock: Sendable {
    /// The current instant used for retention decisions.
    var now: Date { get }
}

/// The production wall clock for activity retention.
public struct SystemAgentActivityClock: AgentActivityClock, Sendable {
    public init() {}
    public var now: Date { Date() }
}
