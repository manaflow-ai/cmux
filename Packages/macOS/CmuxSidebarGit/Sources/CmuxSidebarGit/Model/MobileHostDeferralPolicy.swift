public import Foundation

/// Policy for deferring background git/PR work while the paired mobile host
/// is actively serving requests, so sidebar polling never contends with live
/// mobile traffic.
///
/// Both services share one policy value (single source of truth for the two
/// legacy `TabManager` constants); tests inject shorter intervals.
public struct MobileHostDeferralPolicy: Equatable, Sendable {
    /// Minimum deferral before background work retries after mobile-host
    /// activity was observed (seconds).
    public let deferralInterval: TimeInterval
    /// How long the mobile host must stay quiet before background work
    /// resumes (seconds).
    public let quietInterval: TimeInterval

    /// Creates a policy.
    public init(deferralInterval: TimeInterval, quietInterval: TimeInterval) {
        self.deferralInterval = deferralInterval
        self.quietInterval = quietInterval
    }

    /// The production policy (the legacy `TabManager` constants:
    /// 2s deferral floor, 60s quiet window).
    public static let standard = MobileHostDeferralPolicy(
        deferralInterval: 2.0,
        quietInterval: 60.0
    )
}
