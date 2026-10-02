#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// One plan on sale: its name, StoreKit price, allowances and purchase button.
///
/// HIG: In-app purchase (show the full renewal price from StoreKit as the
/// most prominent price, never a hardcoded amount).
struct MobilePlanOfferRow: View {
    let offer: BillingOffer
    /// True when this offer is the account's current App Store plan.
    let isCurrent: Bool
    /// True when the account already has a different App Store plan, so the
    /// button switches plans within the subscription group.
    let isSwitch: Bool
    let isBusy: Bool
    let buy: () -> Void

    var body: some View {
        let copy = BillingPlanCopy(planID: offer.planID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(copy.name)
                    .font(.headline)
                Spacer(minLength: 12)
                Text(priceText)
                    .font(.headline)
                    .monospacedDigit()
                    .accessibilityIdentifier("BillingOfferPrice.\(offer.planID.rawValue)")
            }
            ForEach(copy.features, id: \.self) { feature in
                Label(feature, systemImage: "checkmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            Button(action: buy) {
                Text(buttonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCurrent || isBusy)
            .accessibilityIdentifier("BillingOfferBuy.\(offer.planID.rawValue)")
        }
        .padding(.vertical, 4)
    }

    private var priceText: String {
        guard let unit = offer.product.periodUnitName, !unit.isEmpty else { return offer.product.displayPrice }
        return String(
            format: L10n.string("mobile.billing.pricePerPeriod", defaultValue: "%1$@ / %2$@"),
            offer.product.displayPrice,
            unit
        )
    }

    private var buttonTitle: String {
        if isCurrent {
            return L10n.string("mobile.billing.offer.current", defaultValue: "Current Plan")
        }
        if isSwitch {
            return L10n.string("mobile.billing.offer.switch", defaultValue: "Switch to This Plan")
        }
        return L10n.string("mobile.billing.offer.subscribe", defaultValue: "Subscribe")
    }
}
#endif
