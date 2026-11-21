#if os(iOS)
import CmuxMobileBilling
import CmuxMobileBillingUI
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// First-run setup's plans page, before "Start your first agent", laid out the way
/// the best AI apps' paywalls are (ChatGPT, Perplexity, Claude; Aziz 2026-11-19:
/// "look at how other apps do billing onboarding"): one value headline, a tier
/// switcher (Pro, Max) with Pro picked, two period cards with
/// the yearly saving, one call to action with the price under it, and "Not now"
/// in the navigation bar. No trial toggle (App Review 3.1.2). The real
/// ``BillingModel``: StoreKit prices in the buyer's currency, the App Store
/// purchase, Restore Purchases, and the renewal disclosure with Terms and Privacy.
/// Setup skips it unless the account is on Free and can buy in the app
/// (`BillingAccountState.setupSkipsPlans`).
struct OnboardingPlansPage: View {
    let next: () -> Void
    @Environment(BillingModel.self) private var billing
    @State private var period: BillingPeriod = .yearly
    /// The tier the switcher shows; nil until offers load, then Pro (or the first sold).
    @State private var tier: BillingPlanID?
    @State private var left = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    plans.padding(.top, 28)
                    if let message = statusMessage {
                        Text(message)
                            .font(theme.type.rowSubtitle)
                            .foregroundStyle(theme.colors.label2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 14)
                            .accessibilityIdentifier("setup.plans.status")
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        // Accessibility sizes: the button scrolls with the page, so a pinned
                        // footer never squeezes the plans into a sliver.
                        actions.padding(.top, 24)
                    }
                    legal.padding(.top, 32)
                }
                .padding(.horizontal, theme.metrics.sideMargin)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // On the scroll view only: an identifier on the whole page replaces its buttons' own.
            .accessibilityIdentifier("setup.plans")
            if !dynamicTypeSize.isAccessibilitySize {
                actions
                    .frame(maxWidth: 560)
                    .padding(.horizontal, theme.metrics.sideMargin)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
        }
        .background(theme.colors.bg.color.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Not now") { leave() }
                    .disabled(billing.purchase.isPurchasing)
                    .accessibilityIdentifier("setup.plans.free")
            }
        }
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
        .onChange(of: tiers, initial: true) { _, tiers in
            if let tier, tiers.contains(tier) { return }
            tier = tiers.contains(.pro) ? .pro : tiers.first
        }
    }

    // MARK: Hero

    /// What a plan changes, in two lines: no picture, no list (Aziz 2026-11-20:
    /// "too much going on").
    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep agents running with your Mac closed")
                .font(theme.type.welcomeTitle)
                .foregroundStyle(theme.colors.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Your agents move to Cloud VMs, and you start and steer them from here.")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Plans

    @ViewBuilder private var plans: some View {
        switch billing.account {
        case .idle, .loading:
            loadingRow
        case .failed:
            EmptyView()
        case .loaded:
            if tiers.isEmpty {
                if billing.offersFailure != nil { retryRow } else { loadingRow }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if tiers.count > 1 {
                        Picker("Plan", selection: Binding(get: { tier ?? tiers[0] }, set: { tier = $0 })) {
                            ForEach(tiers, id: \.self) { id in
                                Text(BillingPlanCopy(planID: id).name).tag(id)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(billing.purchase.isPurchasing)
                        .accessibilityIdentifier("setup.plans.tier")
                    }
                    if let tier {
                        periodCards(for: tier)
                        Text(BillingPlanCopy(planID: tier).features.joined(separator: " · "))
                            .font(theme.type.meta)
                            .foregroundStyle(theme.colors.label2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("setup.plans.features")
                    }
                }
            }
        }
    }

    /// The tier's periods side by side, yearly first with its saving.
    @ViewBuilder private func periodCards(for tier: BillingPlanID) -> some View {
        let sold = billing.offers.filter { $0.planID == tier }
        let yearly = sold.first { $0.billingPeriod == .yearly }
        let monthly = sold.first { $0.billingPeriod == .monthly }
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            if let yearly {
                PeriodCard(title: "Yearly", perMonth: yearly.product.monthlyEquivalentDisplayPrice ?? yearly.product.displayPrice,
                           billed: "\(yearly.product.displayPrice) a year", badge: savings(yearly: yearly, monthly: monthly),
                           isSelected: period == .yearly || monthly == nil) { period = .yearly }
                    .disabled(billing.purchase.isPurchasing)
                    .accessibilityIdentifier("setup.plans.period.yearly")
            }
            if let monthly {
                PeriodCard(title: "Monthly", perMonth: monthly.product.displayPrice, billed: "Billed monthly", badge: nil,
                           isSelected: period == .monthly || yearly == nil) { period = .monthly }
                    .disabled(billing.purchase.isPurchasing)
                    .accessibilityIdentifier("setup.plans.period.monthly")
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            Text("Plans didn't load. Tap Not now to start on Free; you can pick a plan later in Settings.")
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

    /// One button, the price it charges under it. With nothing to buy (loading,
    /// failed, waiting for approval) the button goes on with setup.
    @ViewBuilder private var actions: some View {
        VStack(spacing: 8) {
            if let offer = selectedOffer {
                PrimaryCapsule(LocalizedStringKey(subscribeTitle(offer)), isLoading: billing.purchase.isPurchasing) {
                    Task { await billing.buy(offer, entryPoint: .onboarding) }
                }
                .accessibilityIdentifier("setup.plans.subscribe")
                Text(chargeLine(offer))
                    .font(theme.type.legal)
                    .foregroundStyle(theme.colors.label2)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.plans.charge")
            } else {
                PrimaryCapsule(waitingForApproval ? "Continue" : "Continue with Free") { leave() }
                    .accessibilityIdentifier("setup.plans.continue")
            }
        }
    }

    /// Restore Purchases, Terms, Privacy and the renewal terms, as on Settings → Plans:
    /// one quiet row and the disclosure App Review asks for.
    private var legal: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button("Restore") { Task { await billing.restorePurchases() } }
                    .buttonStyle(.cmuxPressFill)
                    .disabled(billing.restore == .restoring || billing.purchase.isPurchasing)
                    .accessibilityIdentifier("setup.plans.restore")
                Link("Terms", destination: MobilePlansView.termsURL)
                Link("Privacy", destination: MobilePlansView.privacyURL)
            }
            .font(theme.type.legal.weight(.medium))
            .foregroundStyle(theme.colors.label2)
            Text("Renews automatically at the price shown until cancelled. Charged to your Apple Account when you confirm. Cancel any time in your Apple Account settings.")
                .font(theme.type.legal)
                .foregroundStyle(theme.colors.label3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Offers

    /// The plans sold, cheapest first. Go is retired (Aziz 2026-11-20): never offered
    /// here, even while the App Store still lists its products.
    private var tiers: [BillingPlanID] {
        Array(Set(billing.offers.map(\.planID)).subtracting([.go])).sorted()
    }

    /// The offer the button buys: the tier in the chosen period, else the one it is sold in.
    private var selectedOffer: BillingOffer? {
        guard let tier, !waitingForApproval else { return nil }
        let sold = billing.offers.filter { $0.planID == tier && tier != .go }
        return sold.first { $0.billingPeriod == period } ?? sold.first
    }

    /// "Save 20%": a year against twelve months, when StoreKit gave both prices.
    private func savings(yearly: BillingOffer, monthly: BillingOffer?) -> String? {
        guard let year = yearly.product.price, let month = monthly?.product.price, month > 0 else { return nil }
        let percent = Int(((1 - NSDecimalNumber(decimal: year / (month * 12)).doubleValue) * 100).rounded())
        return percent >= 5 ? "Save \(percent)%" : nil
    }

    private func chargeLine(_ offer: BillingOffer) -> String {
        let price = offer.product.displayPrice
        return offer.billingPeriod == .yearly
            ? "\(price) a year. Renews automatically; cancel any time."
            : "\(price) a month. Renews automatically; cancel any time."
    }

    private var waitingForApproval: Bool {
        switch billing.purchase {
        case .pending, .awaitingServer: true
        default: false
        }
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

/// One billing period: its per-month price large, what it bills under it, and
/// its saving as a badge. Selected: the label-colored ring (a held card changes
/// only its fill).
private struct PeriodCard: View {
    let title: LocalizedStringKey
    let perMonth: String
    let billed: String
    let badge: String?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(theme.type.meta.weight(.semibold))
                        .foregroundStyle(theme.colors.label2)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge)
                            .font(theme.type.legal.weight(.semibold))
                            .foregroundStyle(theme.colors.neutralOnAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(theme.colors.label.color, in: .capsule)
                    }
                }
                Text("\(perMonth)/mo")
                    .font(theme.type.rowTitle.weight(.semibold))
                    .foregroundStyle(theme.colors.label)
                    .monospacedDigit()
                Text(billed)
                    .font(theme.type.legal)
                    .foregroundStyle(theme.colors.label2)
                    .monospacedDigit()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PeriodCardStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PeriodCardStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .cmuxMobilePressFill(configuration.isPressed, rest: AnyShapeStyle(theme.colors.surfaceRaised), in: shape)
            .overlay(shape.strokeBorder(isSelected ? theme.colors.label.color : theme.colors.separator.color, lineWidth: isSelected ? 2 : 1))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
#endif
