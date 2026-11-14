#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import Foundation

/// The result line for the last purchase or restore, shared by the plans
/// screen and the paywall.
struct BillingStatusCopy {
    let purchase: BillingPurchasePhase
    let restore: BillingRestorePhase

    /// The message; nil when there is none.
    var resultMessage: String? {
        switch restore {
        case .restoring:
            return L10n.string("mobile.billing.restoring", defaultValue: "Restoring purchases")
        case .completed(let count):
            return count > 0
                ? L10n.string("mobile.billing.restored", defaultValue: "Your purchases were restored.")
                : L10n.string("mobile.billing.restoredNone", defaultValue: "No active App Store subscription was found.")
        case .failed(let failure):
            return BillingFailureCopy(failure: failure).message
        case .idle:
            break
        }
        switch purchase {
        case .idle:
            return nil
        case .purchasing:
            return L10n.string("mobile.billing.purchasing", defaultValue: "Completing your purchase")
        case .pending:
            return L10n.string(
                "mobile.billing.pending",
                defaultValue: "Your purchase is waiting for approval. Your plan updates when it is approved."
            )
        case .completed(let planID):
            return String(
                format: L10n.string("mobile.billing.completed", defaultValue: "You're on %@ now."),
                BillingPlanCopy(planID: planID).name
            )
        case .awaitingServer:
            return L10n.string(
                "mobile.billing.awaitingServer",
                defaultValue: "Purchase complete. Your plan updates as soon as cmux confirms it. You don't need to buy again."
            )
        case .failed(let failure):
            return BillingFailureCopy(failure: failure).message
        }
    }
}

extension BillingPlanSource {
    /// Which billing system grants the plan, for display.
    var displayText: String? {
        switch self {
        case .apple:
            L10n.string("mobile.billing.source.apple", defaultValue: "Billed through the App Store.")
        case .stripe:
            L10n.string("mobile.billing.source.web", defaultValue: "Billed on the web.")
        case .none, .other:
            nil
        }
    }
}

/// Why this account cannot buy in the app, as plain text with no link.
struct BillingIneligibilityCopy {
    let reason: BillingIneligibilityReason?

    var message: String {
        switch reason {
        case .stripeSubscriptionActive:
            // Plain text on purpose: the App Store build must not link to web
            // billing (App Review Guideline 3.1.1).
            L10n.string(
                "mobile.billing.ineligible.web",
                defaultValue: "You subscribe on the web."
            )
        case .teamBilling:
            L10n.string(
                "mobile.billing.ineligible.team",
                defaultValue: "Your team admin manages billing for this account."
            )
        case .purchasesUnavailable:
            L10n.string(
                "mobile.billing.ineligible.unavailable",
                defaultValue: "Plans can't be bought in this version of the app."
            )
        case .other, .none:
            L10n.string(
                "mobile.billing.ineligible.other",
                defaultValue: "Plans can't be bought in the app for this account."
            )
        }
    }
}
#endif
