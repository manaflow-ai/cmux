import Foundation

/// Where the user opened the plans screen; sent as `entry_point` on the
/// paywall funnel events.
public enum BillingEntryPoint: String, Sendable, Equatable {
    /// Settings > Plan.
    case settings
    /// An upgrade action in the Cloud machine sheet.
    case cloudUpgrade = "cloud_upgrade"
}
