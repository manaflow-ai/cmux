import Foundation

/// The client paywall-funnel events from
/// `docs/billing/ios-in-app-purchases.md`, with the `ios_` prefix the mobile
/// analytics proxy requires.
public struct BillingAnalyticsEvent: Sendable, Equatable, Hashable {
    /// The PostHog event name.
    public let name: String

    /// The plans screen appeared.
    public static let paywallViewed = BillingAnalyticsEvent(name: "ios_paywall_viewed")
    /// The user tapped a plan's purchase button.
    public static let purchaseStarted = BillingAnalyticsEvent(name: "ios_purchase_started")
    /// The user dismissed the App Store purchase sheet.
    public static let purchaseCancelled = BillingAnalyticsEvent(name: "ios_purchase_cancelled")
    /// The purchase failed before the App Store completed it, or StoreKit
    /// could not verify it.
    public static let purchaseFailed = BillingAnalyticsEvent(name: "ios_purchase_failed")
    /// The purchase waits for approval (Ask to Buy).
    public static let purchasePending = BillingAnalyticsEvent(name: "ios_purchase_pending")
    /// The user tapped Restore Purchases.
    public static let restoreStarted = BillingAnalyticsEvent(name: "ios_restore_started")
    /// Restore Purchases finished, successfully or not.
    public static let restoreCompleted = BillingAnalyticsEvent(name: "ios_restore_completed")
}
