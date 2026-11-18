#if os(iOS)
import CmuxMobileBilling
import CmuxMobileBillingUI
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// First-run setup's plans page, before "Start your first agent" (ChatGPT's and
/// Perplexity's post-onboarding plan pick, with Free one tap away). Free runs
/// agents on your Macs; a paid plan adds Cloud VMs. The real ``BillingModel``:
/// StoreKit prices in the buyer's currency, the App Store purchase, Restore
/// Purchases, and the renewal disclosure with Terms and Privacy (App Review
/// Guideline 3.1.2). Setup skips it unless the account is on Free and can buy
/// in the app (`BillingAccountState.setupSkipsPlans`).
struct OnboardingPlansPage: View {
    let next: () -> Void
    @Environment(BillingModel.self) private var billing
    @State private var period: BillingPeriod = .yearly
    /// The chosen card: `.free` until the person picks a paid plan.
    @State private var selected: BillingPlanID = .free
    @State private var left = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if periodChoice {
                        Picker("Billing period", selection: $period) {
                            Text("Monthly").tag(BillingPeriod.monthly)
                            Text("Yearly").tag(BillingPeriod.yearly)
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 20)
                        .accessibilityIdentifier("setup.plans.period")
                    }
                    cards.padding(.top, 16)
                    if let message = statusMessage {
                        Text(message)
                            .font(theme.type.rowSubtitle)
                            .foregroundStyle(theme.colors.label2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 14)
                            .accessibilityIdentifier("setup.plans.status")
                    }
                    legal.padding(.top, 20)
                }
                .padding(.horizontal, theme.metrics.sideMargin)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // On the scroll view only: an identifier on the whole page replaces its buttons' own.
            .accessibilityIdentifier("setup.plans")
            actions
                .frame(maxWidth: 560)
                .padding(.horizontal, theme.metrics.sideMargin)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(theme.colors.bg.color.ignoresSafeArea())
        .task {
            billing.paywallViewed(entryPoint: .onboarding)
            await billing.refresh()
        }
        .onChange(of: billing.purchase) { _, phase in
            if case .completed = phase { leave() }
        }
        // Loaded as one the page has nothing to offer (another account's plan, team billing):
        // on with setup, nothing to choose.
        .onChange(of: billing.account, initial: true) { _, account in
            if account.setupSkipsPlans, !billing.purchase.isPurchasing { leave() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep agents running when your Mac sleeps")
                .font(theme.type.sidebarTitle)
                .foregroundStyle(theme.colors.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Free runs agents on your own Macs. A plan adds Cloud VMs, so agents keep working with your laptop closed. Change it any time in Settings.")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var cards: some View {
        VStack(spacing: 10) {
            PlanCard(name: BillingPlanCopy(planID: .free).name, price: nil, detail: "Agents on your own Macs",
                     features: ["Chief, workspaces and this app", "Every agent your Macs run"],
                     isSelected: selected == .free) { selected = .free }
                .accessibilityIdentifier("setup.plans.card.free")
            switch billing.account {
            case .idle, .loading:
                loadingRow
            case .failed:
                EmptyView()
            case .loaded:
                if offers.isEmpty {
                    if billing.offersFailure != nil {
                        retryRow
                    } else {
                        loadingRow
                    }
                } else {
                    ForEach(offers) { offer in
                        let copy = BillingPlanCopy(planID: offer.planID)
                        PlanCard(name: copy.name, price: price(offer), detail: monthly(offer),
                                 features: copy.features, isSelected: selected == offer.planID) { selected = offer.planID }
                            .disabled(billing.purchase.isPurchasing)
                            .accessibilityIdentifier("setup.plans.card.\(offer.planID.rawValue)")
                    }
                }
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading plans")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .accessibilityIdentifier("setup.plans.loading")
    }

    private var retryRow: some View {
        VStack(spacing: 8) {
            Text("Plans didn't load. You can start on Free and pick a plan later in Settings.")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TextCTA("Try again") { Task { await billing.refresh() } }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityIdentifier("setup.plans.failed")
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 6) {
            if let offer = selectedOffer {
                PrimaryCapsule(LocalizedStringKey(subscribeTitle(offer)), isLoading: billing.purchase.isPurchasing) {
                    Task { await billing.buy(offer, entryPoint: .onboarding) }
                }
                .accessibilityIdentifier("setup.plans.subscribe")
                TextCTA("Continue with Free") { leave() }
                    .disabled(billing.purchase.isPurchasing)
                    .accessibilityIdentifier("setup.plans.free")
            } else {
                PrimaryCapsule(waitingForApproval ? "Continue" : "Continue with Free") { leave() }
                    .accessibilityIdentifier("setup.plans.free")
            }
        }
    }

    /// Restore Purchases, Terms, Privacy and the renewal terms, under the plans as on
    /// Settings → Plans.
    private var legal: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Button("Restore Purchases") { Task { await billing.restorePurchases() } }
                    .buttonStyle(.cmuxPressFill)
                    .disabled(billing.restore == .restoring || billing.purchase.isPurchasing)
                    .accessibilityIdentifier("setup.plans.restore")
                Link("Terms of Use", destination: MobilePlansView.termsURL)
                Link("Privacy Policy", destination: MobilePlansView.privacyURL)
            }
            .font(theme.type.meta.weight(.medium))
            .foregroundStyle(theme.colors.label)
            Text("Subscriptions renew automatically at the end of each month or year, as shown, at the price shown until cancelled. Payment is charged to your Apple Account when you confirm the purchase. Manage or cancel your subscription in your Apple Account settings.")
                .font(theme.type.legal)
                .foregroundStyle(theme.colors.label3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Offers

    /// One offer per plan: the chosen period when the plan has it, else the one it is sold in.
    private var offers: [BillingOffer] {
        var byPlan: [BillingPlanID: BillingOffer] = [:]
        for offer in billing.offers {
            if let existing = byPlan[offer.planID], existing.billingPeriod == period { continue }
            byPlan[offer.planID] = offer
        }
        return byPlan.values.sorted { $0.planID < $1.planID }
    }

    private var periodChoice: Bool {
        Dictionary(grouping: billing.offers, by: \.planID).values.contains { Set($0.map(\.billingPeriod)).count > 1 }
    }

    private var selectedOffer: BillingOffer? {
        guard selected != .free, !waitingForApproval else { return nil }
        return offers.first { $0.planID == selected }
    }

    private var waitingForApproval: Bool {
        switch billing.purchase {
        case .pending, .awaitingServer: true
        default: false
        }
    }

    private func price(_ offer: BillingOffer) -> String {
        guard let unit = offer.product.periodUnitName, !unit.isEmpty else { return offer.product.displayPrice }
        return "\(offer.product.displayPrice) / \(unit)"
    }

    private func monthly(_ offer: BillingOffer) -> String? {
        offer.product.monthlyEquivalentDisplayPrice.map { "\($0) / month, billed yearly" }
    }

    private func subscribeTitle(_ offer: BillingOffer) -> String {
        "Subscribe to \(BillingPlanCopy(planID: offer.planID).name)"
    }

    private var statusMessage: String? {
        switch billing.purchase {
        case .idle, .completed: nil
        case .purchasing: "Completing your purchase"
        case .pending: "Your purchase is waiting for approval. Your plan updates when it is approved."
        case .awaitingServer: "Purchase complete. Your plan updates as soon as cmux confirms it. You don't need to buy again."
        case .failed(let failure):
            failure == .purchasesNotAllowed
                ? "Purchases aren't allowed on this iPhone. You can start on Free."
                : "The purchase didn't go through. Try again, or start on Free."
        }
    }

    private func leave() {
        guard !left else { return }
        left = true
        next()
    }
}

/// One plan: a radio mark, the name and price, a detail line, and its allowances.
/// Selected: the label-colored ring (a held card changes only its fill).
private struct PlanCard: View {
    let name: String
    let price: String?
    let detail: String?
    let features: [String]
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(theme.type.rowTitle)
                    .foregroundStyle(isSelected ? theme.colors.label : theme.colors.label3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(name)
                            .font(theme.type.rowTitle.weight(.semibold))
                            .foregroundStyle(theme.colors.label)
                        Spacer(minLength: 8)
                        if let price {
                            Text(price)
                                .font(theme.type.rowTitle.weight(.semibold))
                                .foregroundStyle(theme.colors.label)
                                .monospacedDigit()
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(theme.type.meta)
                            .foregroundStyle(theme.colors.label2)
                            .monospacedDigit()
                    }
                    ForEach(features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark")
                            .font(theme.type.meta)
                            .foregroundStyle(theme.colors.label2)
                            .labelStyle(.titleAndIcon)
                    }
                    .padding(.top, 2)
                }
                .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PlanCardStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PlanCardStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .cmuxMobilePressFill(configuration.isPressed, rest: AnyShapeStyle(theme.colors.surfaceRaised), in: shape)
            .overlay(shape.strokeBorder(isSelected ? theme.colors.label.color : .clear, lineWidth: 2))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
#endif
