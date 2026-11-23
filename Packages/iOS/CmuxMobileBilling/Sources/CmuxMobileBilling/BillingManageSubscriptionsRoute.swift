import Foundation

/// Where Manage Subscription takes the user.
///
/// StoreKit's sheet (`manageSubscriptionsSheet`, `showManageSubscriptions`)
/// is refused for the iOS app running on a Mac: StoreKit logs "The manage
/// subscriptions sheet is not supported on Catalyst apps" and fails with
/// `StoreKitError.unknown`, so the button opened nothing there (Sandbox run on
/// macOS 27.0.1, 2026-11-18). Apple's documentation says to avoid that UI
/// when `isiOSAppOnMac`; the Mac App Store's own subscriptions page is the
/// way to cancel there.
public enum BillingManageSubscriptionsRoute: Sendable, Equatable {
    /// StoreKit's in-app manage subscriptions sheet.
    case storeKitSheet
    /// The App Store's subscriptions page, opened as a URL.
    case appStorePage(URL)

    /// The App Store subscriptions page. `itms-apps` opens the App Store app
    /// itself on a Mac; an `https` link would open a browser first.
    public static let appStoreSubscriptionsURL = URL(string: "itms-apps://apps.apple.com/account/subscriptions")!

    /// The same page on the web, for when nothing handles `itms-apps`.
    public static let webSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    /// The route for this process.
    /// - Parameter isiOSAppOnMac: `ProcessInfo.processInfo.isiOSAppOnMac`.
    /// - Returns: The App Store page on a Mac, StoreKit's sheet elsewhere.
    public static func route(isiOSAppOnMac: Bool) -> Self {
        isiOSAppOnMac ? .appStorePage(appStoreSubscriptionsURL) : .storeKitSheet
    }
}
