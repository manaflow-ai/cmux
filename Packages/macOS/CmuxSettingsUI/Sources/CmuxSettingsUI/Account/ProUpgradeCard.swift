import CmuxFoundation
import SwiftUI

/// Upgrade row rendered below the identity card in the Account section.
///
/// Shows the cmux Pro pitch (one title line + one price/value subtitle)
/// with a trailing button that asks the host to open the pricing page in
/// the default browser via ``AccountFlow/openProUpgrade()`` or the billing
/// portal via ``AccountFlow/openBillingPortal()`` for active subscribers.
@MainActor
struct ProUpgradeCard: View {
    let flow: AccountFlow?

    init(flow: AccountFlow?) {
        self.flow = flow
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.account.pro.title", defaultValue: "cmux Pro"))
                    .cmuxFont(size: 13, weight: .medium)
                Text(subtitleText)
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                if flow?.isProActive == true {
                    flow?.openBillingPortal()
                } else {
                    flow?.openProUpgrade()
                }
            } label: {
                Text(buttonTitle)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .task(id: flow?.currentIdentity?.id ?? "") {
            await flow?.refreshBillingPlan()
        }
    }

    private var subtitleText: String {
        if flow?.isProActive == true {
            return String(
                localized: "settings.account.pro.activeSubtitle",
                defaultValue: "Your Pro subscription is active. Manage billing or cancel in Stripe."
            )
        }
        return String(
            localized: "settings.account.pro.subtitle",
            defaultValue: "Cloud dev boxes, the iOS app, and cmux AI. $30/month, or $240/year."
        )
    }

    private var buttonTitle: String {
        if flow?.isProActive == true {
            return String(localized: "settings.account.pro.manageBilling", defaultValue: "Manage billing")
        }
        return String(localized: "settings.account.pro.upgrade", defaultValue: "Upgrade…")
    }
}
