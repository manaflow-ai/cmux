/// Supplies retry jitter for ``AgentSyncEngine``.
public protocol AgentSyncJitter: Sendable {
    /// Returns a multiplier delta in the range `-0.2...0.2`.
    /// - Returns: A fractional jitter value.
    func retryJitterFraction() -> Double
}
