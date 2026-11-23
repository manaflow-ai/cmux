import Foundation

/// Whether the plans screen offers anything to buy in this app.
///
/// Every App Store app record sells cmux plans only if it has its own
/// subscriptions: product ids are `<bundleId>.<plan>.<period>`
/// (`docs/billing/ios-in-app-purchases.md`). An app whose record has none
/// cannot complete a purchase, so its plans screen shows the current plan
/// read-only: no prices, no purchase or restore controls, no subscription
/// terms, and no text saying plans can't be bought here (App Review 2.1 and
/// 3.1.1).
///
/// Apps outside ``appsWithoutSubscriptions`` always offer purchases, exactly
/// as before this type existed. An app inside it offers them as soon as the
/// server sells to it (`APPLE_IAP_BUNDLE_IDS`) and StoreKit loads its
/// products, with no app change.
public struct BillingPurchaseAvailability {
    public init() {}
    /// Bundle ids of App Store app records with no subscriptions.
    /// `dev.cmux.app.internal`: App Store Connect app "cmux INTERNAL"
    /// (6791408425), built by the TestFlight configuration.
    public static let appsWithoutSubscriptions: Set<String> = ["dev.cmux.app.internal"]

    /// Whether the plans screen offers purchases, restore, subscription
    /// management and the auto-renewal terms.
    /// - Parameters:
    ///   - bundleIdentifier: The app's bundle id; nil for a host that did not
    ///     name one, which keeps purchases offered.
    ///   - account: The account-token state.
    ///   - offers: The offers StoreKit loaded.
    /// - Returns: True unless the app's record has no subscriptions and the
    ///   server and StoreKit have not both made an offer buyable.
    public static func offersPurchases(
        bundleIdentifier: String?,
        account: BillingAccountState,
        offers: [BillingOffer]
    ) -> Bool {
        guard let bundleIdentifier, appsWithoutSubscriptions.contains(bundleIdentifier) else { return true }
        guard let account = account.account, account.eligible else { return false }
        return !offers.isEmpty
    }
}
