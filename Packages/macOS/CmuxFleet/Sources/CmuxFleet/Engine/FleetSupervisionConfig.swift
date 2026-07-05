/// Stores deterministic Fleet supervision limits.
public struct FleetSupervisionConfig: Equatable, Codable, Sendable {
    /// The maximum number of agent launch attempts before a task fails.
    public var maxAttempts: Int

    /// The maximum retry backoff delay in milliseconds.
    public var maxRetryBackoffMS: Int

    /// The stall timeout in milliseconds; timers are owned by the imperative engine.
    public var stallTimeoutMS: Int

    /// Creates Fleet supervision limits.
    /// - Parameters:
    ///   - maxAttempts: The maximum number of agent launch attempts before failure.
    ///   - maxRetryBackoffMS: The maximum retry backoff delay in milliseconds.
    ///   - stallTimeoutMS: The stall timeout in milliseconds.
    public init(
        maxAttempts: Int = 3,
        maxRetryBackoffMS: Int = 300_000,
        stallTimeoutMS: Int = 900_000
    ) {
        self.maxAttempts = maxAttempts
        self.maxRetryBackoffMS = maxRetryBackoffMS
        self.stallTimeoutMS = stallTimeoutMS
    }
}
