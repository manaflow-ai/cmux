import Foundation

/// The client paywall-funnel events from
/// `docs/billing/ios-in-app-purchases.md`, with the `ios_` prefix the mobile
/// analytics proxy requires.
public struct BillingAnalyticsEvent: Sendable, Equatable, Hashable {
    /// The PostHog event name.
    public let name: String

    /// The plans screen or the paywall appeared. Properties: `entry_point`,
    /// and on the paywall `paywall_experiment`, `paywall_variant`,
    /// `paywall_layout`, `paywall_config_source`.
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
    /// The paywall's purchase button was tapped. Properties: `plan_id`,
    /// `billing_period`, `paywall_experiment`, `paywall_variant`,
    /// `entry_point`, `paywall_layout`, `paywall_config_source`.
    public static let paywallCTATapped = BillingAnalyticsEvent(name: "ios_paywall_cta_tapped")
    /// The paywall closed. Properties: `seconds_visible`, `reached_purchase`,
    /// `paywall_experiment`, `paywall_variant`, `entry_point`,
    /// `paywall_layout`, `paywall_config_source`.
    public static let paywallDismissed = BillingAnalyticsEvent(name: "ios_paywall_dismissed")
    /// An upgrade card or banner appeared, once per screen appearance.
    /// Properties: `entry_point`.
    public static let upgradeEntryViewed = BillingAnalyticsEvent(name: "ios_upgrade_entry_viewed")
    /// The paywall showed a free trial offer. Properties: `paywall_variant`,
    /// `paywall_experiment`, `entry_point`, `plan_id`, `billing_period`.
    public static let trialOfferShown = BillingAnalyticsEvent(name: "ios_trial_offer_shown")
    /// The device proof a trial needs failed, so no trial was shown.
    /// Properties: `reason`.
    public static let trialAttestFailed = BillingAnalyticsEvent(name: "ios_trial_attest_failed")
}
