import Foundation

/// A finite automatic recovery episode, shared by link and pane owners.
/// Only success, a machine state change or an explicit retry starts a new episode.
public struct CloudVMRetryEpisode: Sendable, Equatable {
    private let policy: CloudVMRetryPolicy
    private var startedAt: Date?
    private var retryAt: Date?
    public private(set) var attempts = 0
    public private(set) var isStopped = false
    public var hasExpired: Bool {
        startedAt.map { Date.now.timeIntervalSince($0) >= policy.maximumElapsedSeconds } ?? false
    }

    /// Creates an episode using the same policy as VM HTTP requests.
    public init(policy: CloudVMRetryPolicy = .automatic) { self.policy = policy }

    /// Whether the owner may attempt work now, without consuming another attempt.
    public func admitsAttempt(now: Date = .now) -> Bool {
        guard !isStopped else { return false }
        if let startedAt, now.timeIntervalSince(startedAt) >= policy.maximumElapsedSeconds { return false }
        return retryAt.map { now >= $0 } ?? true
    }

    /// Records one failed operation; typed HTTP refusals retain the server's policy.
    /// Local transport failures use the same finite backoff without inventing an HTTP status.
    @discardableResult
    public mutating func recordFailure(
        _ error: Error?, now: Date = .now, jitter: Double = 0
    ) -> CloudVMRetryPolicy.Decision {
        guard !isStopped else { return .stop }
        attempts += 1
        if startedAt == nil { startedAt = now }
        let decision = policy.decision(
            for: (error as? VMClientError)?.cloudHTTPError,
            attempt: attempts, elapsedSeconds: now.timeIntervalSince(startedAt ?? now), jitter: jitter
        )
        if case .retry(let delay) = decision {
            let parts = delay.components
            retryAt = now.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        } else {
            isStopped = true
            retryAt = nil
        }
        return decision
    }

    /// Ends the episode without scheduling more work.
    public mutating func stop() { isStopped = true; retryAt = nil }

    /// Starts a new episode after a successful operation or an authorized reset.
    public mutating func reset() { self = Self(policy: policy) }
}
