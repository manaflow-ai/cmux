#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import Foundation

/// The localized message for a ``BillingFailure``.
struct BillingFailureCopy: Equatable {
    /// The failure to describe.
    let failure: BillingFailure

    /// A one-sentence, user-facing explanation.
    var message: String {
        switch failure {
        case .notSignedIn:
            L10n.string("mobile.billing.error.signedOut", defaultValue: "Sign in to cmux to manage your plan.")
        case .network:
            L10n.string(
                "mobile.billing.error.network",
                defaultValue: "Couldn't reach the App Store or cmux. Check your connection and try again."
            )
        case .accountMismatch:
            L10n.string(
                "mobile.billing.error.accountMismatch",
                defaultValue: "This subscription belongs to another cmux account. Sign in with that account to use it."
            )
        case .server where failure.isPermanentRejection:
            L10n.string(
                "mobile.billing.error.rejected",
                defaultValue: "cmux can't apply this purchase to your account. Contact cmux support for help."
            )
        case .server, .invalidResponse:
            L10n.string("mobile.billing.error.server", defaultValue: "cmux couldn't confirm this right now. Try again later.")
        case .unverified:
            L10n.string("mobile.billing.error.unverified", defaultValue: "The App Store couldn't verify this purchase.")
        case .productUnavailable:
            L10n.string("mobile.billing.error.unavailable", defaultValue: "Plans aren't available in the app right now.")
        case .purchasesNotAllowed:
            L10n.string("mobile.billing.error.notAllowed", defaultValue: "Purchases are turned off on this device.")
        case .notEligible:
            L10n.string("mobile.billing.error.notEligible", defaultValue: "This account can't buy plans in the app.")
        case .store:
            L10n.string("mobile.billing.error.store", defaultValue: "The App Store couldn't complete the request. Try again.")
        }
    }
}
#endif
