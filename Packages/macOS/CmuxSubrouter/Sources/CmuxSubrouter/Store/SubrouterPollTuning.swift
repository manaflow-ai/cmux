public import Foundation

/// Poll cadence and backoff tuning for ``SubrouterStore``.
///
/// The store never polls while no subrouter UI surface is visible, so these
/// intervals only apply while the Agents panel or the footer switcher is on
/// screen. All values are injectable for tests.
public struct SubrouterPollTuning: Sendable, Equatable {
    /// The default tuning used in production.
    public static let standard = SubrouterPollTuning()

    /// Poll interval while the Agents panel is visible. The daemon caches
    /// usage upstream for ~30s, so polling faster only re-reads its cache.
    public var panelPollInterval: TimeInterval
    /// Poll interval while only the footer switcher is visible.
    public var backgroundPollInterval: TimeInterval
    /// First retry delay after a failure (health probe cadence while the
    /// daemon is unreachable). Doubles per consecutive failure.
    public var failureBackoffBase: TimeInterval
    /// Ceiling for the failure backoff.
    public var failureBackoffMax: TimeInterval
    /// Random jitter applied to every deadline, as a fraction of the base.
    public var jitterFraction: Double
    /// Snapshot age beyond which a surface becoming visible triggers an
    /// immediate refresh instead of waiting for the next deadline.
    public var staleAfter: TimeInterval

    /// Creates a tuning value.
    /// - Parameters:
    ///   - panelPollInterval: Cadence while the panel is visible.
    ///   - backgroundPollInterval: Cadence while only the footer is visible.
    ///   - failureBackoffBase: First retry delay after a failure.
    ///   - failureBackoffMax: Backoff ceiling.
    ///   - jitterFraction: Deadline jitter fraction.
    ///   - staleAfter: Snapshot age that forces a refresh on visibility.
    public init(
        panelPollInterval: TimeInterval = 20,
        backgroundPollInterval: TimeInterval = 120,
        failureBackoffBase: TimeInterval = 5,
        failureBackoffMax: TimeInterval = 300,
        jitterFraction: Double = 0.10,
        staleAfter: TimeInterval = 30
    ) {
        self.panelPollInterval = panelPollInterval
        self.backgroundPollInterval = backgroundPollInterval
        self.failureBackoffBase = failureBackoffBase
        self.failureBackoffMax = failureBackoffMax
        self.jitterFraction = jitterFraction
        self.staleAfter = staleAfter
    }
}
