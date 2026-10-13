import CmuxFoundation
import SwiftUI

/// Upgrade row rendered below the identity card in the Account section.
///
/// Shows the next personal plan pitch (one title line + one price/value subtitle)
/// with a trailing button that asks the host to open the pricing page in
/// the default browser via ``AccountFlow/openProUpgrade()`` or the billing
/// portal via ``AccountFlow/openBillingPortal()`` for Stripe-managed subscribers.
@MainActor
struct ProUpgradeCard: View {
    let flow: AccountFlow?

    init(flow: AccountFlow?) {
        self.flow = flow
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .cmuxFont(size: 13, weight: .medium)
                Text(subtitleText)
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if flow?.planAction != nil {
                Button {
                    guard let flow, let action = flow.planAction else { return }
                    switch action {
                    case .manageBilling:
                        flow.openBillingPortal()
                    case .upgradeToPro, .upgradeToMax:
                        flow.openProUpgrade()
                    }
                } label: {
                    Text(buttonTitle)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onHover { hovering in
            // Warm the pricing destination while the pointer is over the row
            // so clicking "Upgrade…" opens an already-loaded page. Managed
            // subscribers get the Stripe portal instead, which the host does
            // not prewarm.
            if hovering, flow?.canManageBilling != true {
                flow?.prefetchProUpgrade()
            }
        }
        .task(id: flow?.currentIdentity?.id ?? "") {
            await flow?.refreshBillingPlan()
        }
    }

    private var subtitleText: String {
        if flow?.isMaxActive == true {
            if flow?.canManageBilling == true {
                return String(
                    localized: "settings.account.max.activeSubtitle",
                    defaultValue: "Your Max subscription is active. Manage billing or cancel it anytime."
                )
            }
            return String(
                localized: "settings.account.max.externalSubtitle",
                defaultValue: "Your Max access is active. Contact support to make changes."
            )
        }
        if flow?.isProActive == true {
            if flow?.canManageBilling == true {
                return String(
                    localized: "settings.account.pro.activeSubtitle",
                    defaultValue: "Your Pro subscription is active. Manage billing or cancel in Stripe."
                )
            }
            return String(
                localized: "settings.account.pro.externalSubtitle",
                defaultValue: "Your subscription is managed by our previous billing system. Contact support to make changes."
            )
        }
        return String(
            localized: "settings.account.pro.subtitle",
            defaultValue: "Up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM, plus the iOS app. $50/month."
        )
    }

    private var buttonTitle: String {
        switch flow?.planAction {
        case .manageBilling:
            return String(localized: "settings.account.pro.manageBilling", defaultValue: "Manage billing")
        case .upgradeToMax:
            return String(localized: "settings.account.pro.upgradeMax", defaultValue: "Upgrade to Max…")
        case .upgradeToPro, nil:
            return String(localized: "settings.account.pro.upgrade", defaultValue: "Upgrade…")
        }
    }

    private var titleText: String {
        if flow?.isMaxActive == true {
            return String(localized: "settings.account.max.title", defaultValue: "cmux Max")
        }
        return String(localized: "settings.account.pro.title", defaultValue: "cmux Pro")
    }

}
