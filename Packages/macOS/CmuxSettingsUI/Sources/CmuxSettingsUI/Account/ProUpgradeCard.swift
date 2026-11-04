import CMUXMobileCore
import CmuxFoundation
import SwiftUI

/// Upgrade row rendered below the identity card in the Account section.
///
/// Shows the cmux Pro pitch (one title line + one price/value subtitle)
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
        let model = ProUpgradeCardModel(
            tier: flow?.planTier,
            isProActive: flow?.isProActive == true,
            canManageBilling: flow?.canManageBilling == true,
            isSignedIn: flow?.currentIdentity != nil,
            billingSource: flow?.planBillingSource
        )
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .cmuxFont(size: 13, weight: .medium)
                Text(model.subtitle)
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            ForEach(model.actions, id: \.self) { action in
                Button {
                    switch action {
                    case .upgradeToPro, .upgradeToMax:
                        flow?.openProUpgrade()
                    case .manageBilling:
                        flow?.openBillingPortal()
                    }
                } label: {
                    Text(action.title)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onHover { hovering in
            // Warm the pricing destination while the pointer is over the row
            // so clicking an upgrade opens an already-loaded page. The
            // billing portal is not prewarmed.
            if hovering, model.actions.contains(where: \.opensPricing) {
                flow?.prefetchProUpgrade()
            }
        }
        .task(id: flow?.currentIdentity?.id ?? "") {
            await flow?.refreshBillingPlan()
        }
    }
}

/// What the Settings plan row says and offers for the account's tier.
///
/// The upgrade always names the next tier: Free and Go are offered Pro, Pro
/// is offered Max, and Max is offered nothing.
struct ProUpgradeCardModel: Equatable {
    enum Action: Hashable {
        case upgradeToPro
        case upgradeToMax
        case manageBilling

        var opensPricing: Bool { self != .manageBilling }

        var title: String {
            switch self {
            case .upgradeToPro:
                String(localized: "settings.account.pro.upgrade", defaultValue: "Upgrade…")
            case .upgradeToMax:
                String(localized: "settings.account.max.upgrade", defaultValue: "Upgrade to Max…", bundle: .module)
            case .manageBilling:
                String(localized: "settings.account.pro.manageBilling", defaultValue: "Manage billing")
            }
        }
    }

    let tier: CmuxPlanTier?
    let title: String
    let subtitle: String
    let actions: [Action]

    /// - Parameters:
    ///   - tier: The account's tier, or `nil` while unknown.
    ///   - isProActive: The legacy paid flag, used when `tier` is `nil`.
    ///   - canManageBilling: Whether the hosted billing portal applies.
    ///   - isSignedIn: Whether an account is signed in. A signed-in account
    ///     whose plan is still unknown is offered nothing, so a Max
    ///     subscriber never sees a Pro upgrade while the plan loads.
    ///   - billingSource: Who bills the plan, or `nil` while unknown. It
    ///     picks the Pro subtitle when the hosted portal does not apply.
    init(
        tier: CmuxPlanTier?,
        isProActive: Bool,
        canManageBilling: Bool,
        isSignedIn: Bool = false,
        billingSource: AccountPlanBillingSource? = nil
    ) {
        // A host that only knows the legacy flag still reads as Pro.
        let tier = tier ?? (isProActive ? .pro : nil)
        self.tier = tier
        switch tier {
        case .max:
            title = String(localized: "settings.account.max.title", defaultValue: "cmux Max", bundle: .module)
            subtitle = String(
                localized: "settings.account.max.activeSubtitle",
                defaultValue: "Your Max subscription is active. It includes everything in Pro.",
                bundle: .module
            )
            actions = canManageBilling ? [.manageBilling] : []
        case .pro:
            title = String(localized: "settings.account.pro.title", defaultValue: "cmux Pro")
            if canManageBilling {
                subtitle = String(
                    localized: "settings.account.pro.activeSubtitle",
                    defaultValue: "Your Pro subscription is active. Manage billing or cancel in Stripe."
                )
                actions = [.upgradeToMax, .manageBilling]
            } else {
                subtitle = Self.unmanagedProSubtitle(billingSource)
                actions = [.upgradeToMax]
            }
        case .free, .go, nil:
            title = String(localized: "settings.account.pro.title", defaultValue: "cmux Pro")
            subtitle = String(
                localized: "settings.account.pro.subtitle",
                defaultValue: "Up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM, plus the iOS app. $50/month."
            )
            if tier == nil && isSignedIn {
                actions = []
            } else if tier == .go && canManageBilling {
                // A Go subscriber still manages or cancels Go in the portal.
                actions = [.upgradeToPro, .manageBilling]
            } else {
                actions = [.upgradeToPro]
            }
        }
    }

    /// The Pro subtitle when the hosted portal does not manage the plan.
    private static func unmanagedProSubtitle(_ billingSource: AccountPlanBillingSource?) -> String {
        switch billingSource {
        case .appStore:
            String(
                localized: "settings.account.pro.appStoreSubtitle",
                defaultValue: "Your Pro subscription is active. Manage it through your subscription provider.",
                bundle: .module
            )
        case .granted:
            // A plan granted by cmux has nothing to bill or manage.
            String(
                localized: "settings.account.pro.grantedSubtitle",
                defaultValue: "Your Pro plan is active.",
                bundle: .module
            )
        case .stripe, nil:
            String(
                localized: "settings.account.pro.externalSubtitle",
                defaultValue: "Your subscription is managed by our previous billing system. Contact support to make changes."
            )
        }
    }
}
