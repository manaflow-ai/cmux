import Foundation

/// The purchase surface the Cloud tab may present for the current storefront.
enum CloudUpgradeRoute: Equatable, Sendable {
    case web
    case inApp
    case unavailable
}

/// Applies the storefront policy to the Cloud upgrade action.
///
/// The app currently has no approved external-purchase entitlement, so the
/// United States storefront is the only storefront where the Cloud tab may
/// open cmux.com directly. Other storefronts use the existing StoreKit plans
/// sheet when billing is available; builds without billing expose no purchase
/// action rather than sending users to an unsupported web checkout.
struct CloudUpgradePolicy: Equatable, Sendable {
    let storefrontCountryCode: String?
    let hasInAppBilling: Bool

    var route: CloudUpgradeRoute {
        if storefrontCountryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "US" {
            return .web
        }
        return hasInAppBilling ? .inApp : .unavailable
    }
}
