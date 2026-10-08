import CmuxFoundation
import Observation
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
    @State private var plan = AccountPlanModel()
    @State private var refreshGeneration = 0
    @Environment(\.scenePhase) private var scenePhase

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
            if presentation == .unavailable {
                Button(String(localized: "settings.account.pro.retry", defaultValue: "Retry", bundle: .module)) {
                    refreshGeneration &+= 1
                }
                .controlSize(.small)
            } else if shouldShowAction {
                Button {
                    if flow?.canManageBilling == true {
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
            // subscribers get the Stripe portal instead, which the host does
            // not prewarm.
            if hovering, presentation == .free {
                flow?.prefetchProUpgrade()
            }
        }
        .task(id: refreshKey) {
            await plan.refresh(flow: flow, key: refreshKey)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshGeneration &+= 1 }
        }
    }

    private var refreshKey: AccountPlanRefreshKey {
        AccountPlanRefreshKey(flow: flow, generation: refreshGeneration)
    }

    private var presentation: AccountPlanModel.Presentation {
        plan.presentation(flow: flow, key: refreshKey)
    }

    private var subtitleText: String {
        if presentation == .checking {
            return String(
                localized: "settings.account.pro.checkingSubtitle",
                defaultValue: "Checking your cmux plan…",
                bundle: .module
            )
        }
        if presentation == .unavailable {
            return String(
                localized: "settings.account.pro.unavailableSubtitle",
                defaultValue: "Could not check your cmux plan. Try again.",
                bundle: .module
            )
        }
        if presentation == .pro || presentation == .managedPro {
            if flow?.canManageBilling == true {
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
        if flow?.canManageBilling == true {
            return String(localized: "settings.account.pro.manageBilling", defaultValue: "Manage billing")
        }
        return String(localized: "settings.account.pro.upgrade", defaultValue: "Upgrade…")
    }

    private var shouldShowAction: Bool {
        presentation == .free || presentation == .managedPro
    }
}

/// The account card must retry the plan lookup after a cached identity has
/// finished session restoration. Keying only on the account ID misses that
/// transition because the identity is available before its tokens are ready.
struct AccountPlanRefreshKey: Equatable {
    let accountID: String?
    let isAuthenticated: Bool
    let isWorkingOnAuth: Bool
    let selectedTeamID: String?
    var generation = 0

    @MainActor
    init(flow: AccountFlow?, generation: Int = 0) {
        accountID = flow?.currentIdentity?.id
        isAuthenticated = flow?.isAuthenticated == true
        isWorkingOnAuth = flow?.isWorkingOnAuth == true
        selectedTeamID = flow?.selectedTeamID
        self.generation = generation
    }

    var canRefresh: Bool {
        accountID != nil && isAuthenticated && !isWorkingOnAuth
    }
}

/// Owns only the card's request/error lifecycle. The host remains the source
/// of truth for entitlement, independent of this Mac's Cloud activation.
@MainActor
@Observable
final class AccountPlanModel {
    enum Presentation: Equatable {
        case checking, unavailable, free, pro, managedPro
    }

    private var failedRefreshKey: AccountPlanRefreshKey?
    @ObservationIgnored private var requestID: UUID?

    func presentation(flow: AccountFlow?, key: AccountPlanRefreshKey) -> Presentation {
        guard !key.isWorkingOnAuth else { return .checking }
        guard flow?.isProStatusKnown != false else {
            return failedRefreshKey == key ? .unavailable : .checking
        }
        if flow?.isProActive == true {
            return flow?.canManageBilling == true ? .managedPro : .pro
        }
        return .free
    }

    func refresh(flow: AccountFlow?, key: AccountPlanRefreshKey) async {
        let id = UUID()
        requestID = id
        failedRefreshKey = nil
        guard let flow, key.canRefresh else { return }
        await flow.refreshBillingPlan()
        guard !Task.isCancelled, requestID == id,
              AccountPlanRefreshKey(flow: flow, generation: key.generation) == key else { return }
        failedRefreshKey = flow.isProStatusKnown ? nil : key
    }
}
