import Foundation

/// The purchase surface the Cloud tab may present for the current storefront.
enum CloudUpgradeRoute: Equatable, Sendable {
    /// StoreKit has not reported the storefront yet. Suppress purchase actions
    /// until the policy can choose the correct surface.
    case pending
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
        guard let storefrontCountryCode else {
            return .pending
        }
        let normalizedCountryCode = storefrontCountryCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalizedCountryCode.isEmpty else {
            return .pending
        }
        if normalizedCountryCode == "US" {
            return .web
        }
        return hasInAppBilling ? .inApp : .unavailable
    }
}
