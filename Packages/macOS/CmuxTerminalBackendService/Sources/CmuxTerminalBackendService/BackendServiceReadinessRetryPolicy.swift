/// Bounded exponential backoff between transient backend startup failures.
public struct BackendServiceReadinessRetryPolicy: Equatable, Sendable {
    /// The first delay after a retryable connection failure.
    public let initialDelay: Duration

    /// The maximum delay between subsequent attempts.
    public let maximumDelay: Duration

    /// The production retry schedule used while launchd starts or restarts the helper.
    public static let launchdStartup = BackendServiceReadinessRetryPolicy(
        initialDelay: .milliseconds(25),
        maximumDelay: .milliseconds(250)
    )

    internal static let immediateForTesting = BackendServiceReadinessRetryPolicy(
        uncheckedInitialDelay: .zero,
        maximumDelay: .zero
    )

    /// Creates a bounded exponential retry policy.
    ///
    /// Production callers should normally use ``launchdStartup``.
    public init(initialDelay: Duration, maximumDelay: Duration) {
        precondition(initialDelay > .zero)
        precondition(maximumDelay >= initialDelay)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }

    private init(uncheckedInitialDelay: Duration, maximumDelay: Duration) {
        initialDelay = uncheckedInitialDelay
        self.maximumDelay = maximumDelay
    }

    internal func nextDelay(after delay: Duration) -> Duration {
        guard delay > .zero else { return maximumDelay }
        guard delay < maximumDelay / 2 else { return maximumDelay }
        return delay * 2
    }
}
