import Foundation

/// Production retry jitter source.
public struct RandomAgentSyncJitter: AgentSyncJitter {
    /// Creates a random jitter source.
    public init() {}

    /// Returns a random retry jitter fraction clamped to the supported bounds.
    /// - Returns: A fractional jitter value.
    public func retryJitterFraction() -> Double {
        Double.random(in: -0.2...0.2)
    }
}
