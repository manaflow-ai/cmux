#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// One plan described without a purchase: its name, allowances and, when the
/// account is on it, a Current Plan mark. Shown when this build or account
/// cannot buy in the App Store, so the plans screen still lists the plans.
///
/// No price and no button: StoreKit has no product to price when the server
/// sells none here, and HIG In-app purchase asks for StoreKit's price, never a
/// hardcoded amount. No link to web billing either (App Review 3.1.1).
struct MobilePlanCatalogRow: View {
    let planID: BillingPlanID
    /// True when this is the account's current plan.
    let isCurrent: Bool

    var body: some View {
        let copy = BillingPlanCopy(planID: planID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(copy.name)
                    .font(.headline)
                Spacer(minLength: 12)
                if isCurrent {
                    Text(L10n.string("mobile.billing.offer.current", defaultValue: "Current Plan"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("BillingCatalogCurrent.\(planID.rawValue)")
                }
            }
            // visible-only: at most 3 fixed, distinct feature strings per plan; each string is its own stable id.
            ForEach(copy.features, id: \.self) { feature in
                Label(feature, systemImage: "checkmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("BillingCatalogPlan.\(planID.rawValue)")
    }
}
#endif
