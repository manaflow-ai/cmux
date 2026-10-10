import CmuxFoundation
import SwiftUI

/// Upgrade row rendered below the identity card in the Account section.
///
/// The host owns the account plan snapshot and all refresh transitions. This
/// view only renders that snapshot and invokes its retry or billing actions.
@MainActor
struct ProUpgradeCard: View {
    let flow: AccountFlow?

    /// Creates the card with the host-owned account and billing state.
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
            if accountPlanStatus == .unavailable {
                Button(String(localized: "settings.account.pro.retry", defaultValue: "Retry", bundle: .module)) {
                    Task { await flow?.retryBillingPlan() }
                }
                .controlSize(.small)
            } else if shouldShowAction {
                Button {
                    if accountPlanStatus == .managedPro {
                        flow?.openBillingPortal()
                    } else {
                        flow?.openProUpgrade()
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
            // subscribers get the billing portal instead, which the host does
            // not prewarm.
            if hovering, accountPlanStatus == .free {
                flow?.prefetchProUpgrade()
            }
        }
    }

    private var accountPlanStatus: AccountPlanStatus {
        flow?.accountPlanStatus ?? .free
    }

    private var subtitleText: String {
        if accountPlanStatus == .checking {
            return String(
                localized: "settings.account.pro.checkingSubtitle",
                defaultValue: "Checking your cmux plan…",
                bundle: .module
            )
        }
        if accountPlanStatus == .unavailable {
            return String(
                localized: "settings.account.pro.unavailableSubtitle",
                defaultValue: "Could not check your cmux plan. Try again.",
                bundle: .module
            )
        }
        if accountPlanStatus == .pro || accountPlanStatus == .managedPro {
            if accountPlanStatus == .managedPro {
                return String(
                    localized: "settings.account.pro.activeSubtitle",
                    defaultValue: "Your Pro subscription is active. Manage billing or cancel anytime."
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
        if accountPlanStatus == .managedPro {
            return String(localized: "settings.account.pro.manageBilling", defaultValue: "Manage billing")
        }
        return String(localized: "settings.account.pro.upgrade", defaultValue: "Upgrade…")
    }

    private var shouldShowAction: Bool {
        accountPlanStatus == .free || accountPlanStatus == .managedPro
    }
}
