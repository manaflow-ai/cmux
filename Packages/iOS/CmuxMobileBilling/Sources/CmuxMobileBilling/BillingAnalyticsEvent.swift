import Foundation

/// The client paywall-funnel events from
/// `docs/billing/ios-in-app-purchases.md`, with the `ios_` prefix the mobile
/// analytics proxy requires.
public struct BillingAnalyticsEvent: Sendable, Equatable, Hashable {
    /// The PostHog event name.
    public let name: String

    /// The plans screen appeared.
    public static let paywallViewed = BillingAnalyticsEvent(name: "ios_paywall_viewed")
    /// StoreKit returned at least one product the server sells to this
    /// bundle. Properties: `product_ids` (comma-separated), `storefront`,
    /// `count`, `billing_period` (the loaded periods, comma-separated).
    public static let productsLoaded = BillingAnalyticsEvent(name: "ios_products_loaded")
    /// An eligible account has no product to buy: StoreKit failed, returned
    /// none of the server's products, or the server listed none. Properties:
    /// `reason`, `storefront`.
    public static let productsFailed = BillingAnalyticsEvent(name: "ios_products_failed")
    /// The user tapped a plan's purchase button.
    public static let purchaseStarted = BillingAnalyticsEvent(name: "ios_purchase_started")
    /// The user dismissed the App Store purchase sheet.
    public static let purchaseCancelled = BillingAnalyticsEvent(name: "ios_purchase_cancelled")
    /// The purchase failed before the App Store completed it, or StoreKit
    /// could not verify it.
    public static let purchaseFailed = BillingAnalyticsEvent(name: "ios_purchase_failed")
    /// The App Store charged the user and StoreKit verified the transaction.
    /// `delivery` is `accepted` when the server applied the plan, `deferred`
    /// when the server step is retried later. Properties: `product_id`,
    /// `plan_id`, `billing_period`, `price`, `currency`, `environment`,
    /// `delivery`.
    public static let purchaseSucceeded = BillingAnalyticsEvent(name: "ios_purchase_succeeded")
    /// The App Store refund request sheet opened from the plans screen.
    /// Properties: `product_id`.
    public static let refundRequestOpened = BillingAnalyticsEvent(name: "ios_refund_request_opened")
    /// The refund request sheet closed. Properties: `product_id`, `result`
    /// (`success`, `userCancelled`, or `error`).
    public static let refundRequestResult = BillingAnalyticsEvent(name: "ios_refund_request_result")
    /// The purchase waits for approval (Ask to Buy).
    public static let purchasePending = BillingAnalyticsEvent(name: "ios_purchase_pending")
    /// The user tapped Restore Purchases.
    public static let restoreStarted = BillingAnalyticsEvent(name: "ios_restore_started")
    /// Restore Purchases finished, successfully or not.
    public static let restoreCompleted = BillingAnalyticsEvent(name: "ios_restore_completed")
}
