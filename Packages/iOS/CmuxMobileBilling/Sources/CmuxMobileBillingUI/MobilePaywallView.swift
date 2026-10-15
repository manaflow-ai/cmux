#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// What the staff Paywall Lab forces on the paywall instead of the account's
/// own state. Purchases and analytics are off in a preview.
public struct BillingPaywallPreview: Sendable, Equatable, Hashable {
    /// The account state the preview shows.
    public enum Scenario: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
        /// The Free account's offers.
        case offers
        /// The offers with a granted free trial.
        case trial
        /// A web subscriber.
        case ineligibleWeb
        /// Team billing.
        case ineligibleTeam
        /// A build that sells nothing.
        case ineligibleUnavailable

        public var id: String { rawValue }
    }

    /// The configuration to render.
    public let config: BillingPaywallConfig
    /// The state to show.
    public let scenario: Scenario
    /// The entry point the preview stands for.
    public let entryPoint: BillingEntryPoint

    /// Creates a preview.
    public init(config: BillingPaywallConfig, scenario: Scenario, entryPoint: BillingEntryPoint) {
        self.config = config
        self.scenario = scenario
        self.entryPoint = entryPoint
    }
}

/// The paywall: a server-configured presentation of the plans on sale.
///
/// The server chooses the layout, the copy and the recommended plan
/// (``BillingPaywallConfig``). Prices, periods and product ids come only from
/// StoreKit and the server's product list. The screen always shows the price
/// and period of the selected plan next to the purchase button, the
/// auto-renewal terms, Restore Purchases, and the Terms and Privacy links
/// (App Review Guidelines 3.1.1 and 3.1.2), and its close button is always
/// visible.
///
/// HIG: In-app purchase, Sheets, and Offering a free trial.
///
/// Present it with ``SwiftUICore/View/billingPaywall(_:onDismiss:)``.
public struct MobilePaywallView: View {
    @Environment(BillingModel.self) private var billing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let entryPoint: BillingEntryPoint
    private let preview: BillingPaywallPreview?

    /// The session, fixed when the paywall first appears.
    @State private var context: BillingPaywallContext?
    @State private var period: BillingPeriod = .yearly
    @State private var selectedPlan: BillingPlanID?
    @State private var showsAllPlans = false
    @State private var appearedAt: ContinuousClock.Instant?
    @State private var reachedPurchase = false
    @State private var dismissReported = false
    @State private var reportedTrial: BillingTrialGrant?
    /// The Paywall Lab's trial, built from real StoreKit prices.
    @State private var previewTrial: BillingTrialGrant?

    /// Creates the paywall.
    /// - Parameters:
    ///   - entryPoint: Where it was opened, for analytics.
    ///   - preview: A Paywall Lab preview; nil for the real paywall.
    public init(entryPoint: BillingEntryPoint, preview: BillingPaywallPreview? = nil) {
        self.entryPoint = entryPoint
        self.preview = preview
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let context {
                    if case .completed(let planID) = billing.purchase, preview == nil {
                        MobilePaywallSuccess(planID: planID, done: { dismiss() })
                    } else {
                        MobilePaywallHeader(config: context.config)
                        content(context)
                    }
                } else {
                    loadingRow
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let context, let offer = selectedOffer, isShowingOffers, !isCompleted {
                MobilePaywallPurchaseBar(
                    offer: offer,
                    config: context.config,
                    trial: trial(for: offer),
                    isCurrent: isCurrent(offer),
                    isSwitch: currentApplePlan != nil,
                    isBusy: billing.purchase.isPurchasing,
                    isPreview: preview != nil,
                    statusMessage: statusMessage,
                    buy: { buy(offer, context: context) }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(L10n.string("mobile.billing.paywall.close", defaultValue: "Close"))
                .accessibilityIdentifier("BillingPaywallClose")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear(perform: reportDismissed)
        .accessibilityIdentifier("BillingPaywallView")
    }

    // MARK: Session

    private func start() async {
        guard context == nil else { return }
        if let preview {
            let fixed = BillingPaywallContext(entryPoint: preview.entryPoint, config: preview.config, configSource: .server)
            apply(fixed)
            if billing.account.account == nil { await billing.loadIfNeeded() }
            await billing.loadPreviewOffers()
            if preview.scenario == .trial { await loadPreviewTrial(preview) }
            return
        }
        let wasLoaded = billing.account.account != nil
        if !wasLoaded { await billing.loadIfNeeded() }
        // Closed while loading: no view and no dismiss event.
        guard !Task.isCancelled else { return }
        let fixed = billing.paywallContext(entryPoint: entryPoint)
        apply(fixed)
        appearedAt = .now
        billing.paywallViewed(context: fixed)
        if wasLoaded { await billing.refresh() }
        await billing.prepareTrial()
        guard !Task.isCancelled else { return }
        if let grant = billing.trial.grant {
            // Lead with the trial: select its plan and period.
            period = grant.billingOffer.billingPeriod
            selectedPlan = grant.planID
        }
    }

    private func apply(_ fixed: BillingPaywallContext) {
        context = fixed
        period = fixed.config.defaultBillingPeriod
        selectedPlan = nil
    }

    private func loadPreviewTrial(_ preview: BillingPaywallPreview) async {
        let monthlyPro = offers.first { $0.planID == .pro && $0.billingPeriod == .monthly }
        let product = await billing.trialPreviewProduct() ?? monthlyPro?.product
        guard let product else { return }
        let offer = product.introductoryOffer.flatMap { $0.isFreeTrial ? $0 : nil }
            ?? StoreIntroductoryOffer(periodValue: 7, periodUnit: .day, periodCount: 1, isFreeTrial: true, isEligibleOnDevice: true)
        previewTrial = BillingTrialGrant(
            planID: .pro,
            product: product,
            introductoryOfferJWS: nil,
            offer: offer,
            limits: BillingTrialLimits(machines: 1, vcpus: 2, memoryGb: 4, vmHours: 20)
        )
        period = .monthly
        selectedPlan = .pro
    }

    private func reportDismissed() {
        guard preview == nil, !dismissReported, let context, let appearedAt else { return }
        dismissReported = true
        let elapsed = appearedAt.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        billing.paywallDismissed(context: context, secondsVisible: seconds, reachedPurchase: reachedPurchase)
        billing.dismissResult()
    }

    private func buy(_ offer: BillingOffer, context: BillingPaywallContext) {
        guard preview == nil else { return }
        reachedPurchase = true
        billing.paywallCTATapped(offer, context: context)
        Task { await billing.buy(offer, context: context, trial: trial(for: offer)) }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ context: BillingPaywallContext) -> some View {
        if let scenario = preview?.scenario, let reason = scenario.ineligibility {
            MobilePaywallNotice(text: BillingStatusCopy.ineligibleText(reason), systemImage: "info.circle")
        } else {
            switch billing.account {
            case .idle, .loading:
                loadingRow
            case .failed(let failure):
                retryNotice(BillingFailureCopy(failure: failure).message)
            case .loaded(let account):
                if account.eligible || preview != nil {
                    offersContent(context)
                } else {
                    MobilePaywallNotice(text: BillingStatusCopy.ineligibleText(account.reason), systemImage: "info.circle")
                        .accessibilityIdentifier("BillingIneligible")
                }
            }
        }
    }

    @ViewBuilder
    private func offersContent(_ context: BillingPaywallContext) -> some View {
        if offers.isEmpty {
            if preview != nil {
                MobilePaywallNotice(
                    text: L10n.string(
                        "mobile.billing.lab.noProducts",
                        defaultValue: "The server lists no App Store products for this account, so there are no prices to show."
                    ),
                    systemImage: "info.circle"
                )
            } else if let failure = billing.offersFailure {
                retryNotice(BillingFailureCopy(failure: failure).message)
            } else {
                loadingRow
            }
        } else {
            let config = context.config
            if !config.bullets.isEmpty {
                MobilePaywallBullets(bullets: config.bullets)
            }
            if hasPeriodChoice {
                MobilePaywallPeriodPicker(
                    period: $period,
                    savingsPercent: config.showYearlySavings ? offers.bestYearlySavingsPercent : nil
                )
            }
            switch config.layout {
            case .cards:
                VStack(spacing: 12) {
                    ForEach(visibleOffers) { offer in
                        planCard(offer, config: config, style: .standard)
                    }
                }
            case .comparison:
                MobilePaywallComparison(plans: comparisonPlans, highlighted: highlightedPlan, accessibilityLayout: dynamicTypeSize.isAccessibilitySize)
                VStack(spacing: 8) {
                    ForEach(visibleOffers) { offer in
                        planCard(offer, config: config, style: .compact)
                    }
                }
            case .focus:
                let focus = focusOffer
                if let focus {
                    planCard(focus, config: config, style: .hero)
                }
                let others = visibleOffers.filter { $0.id != focus?.id }
                if !others.isEmpty {
                    if showsAllPlans {
                        VStack(spacing: 8) {
                            ForEach(others) { offer in
                                planCard(offer, config: config, style: .compact)
                            }
                        }
                    } else {
                        Button {
                            withAnimation(.snappy) { showsAllPlans = true }
                        } label: {
                            HStack(spacing: 4) {
                                Text(L10n.string("mobile.billing.paywall.seeAll", defaultValue: "See all plans"))
                                Image(systemName: "chevron.down")
                                    .font(.footnote.weight(.semibold))
                            }
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("BillingPaywallSeeAll")
                    }
                }
            }
            if let trial = selectedOffer.flatMap(trial(for:)) {
                MobilePaywallTrialTerms(grant: trial)
                    .onAppear { reportTrialShown(trial, context: context) }
            }
            MobilePaywallLegal(isBusy: billing.restore == .restoring || billing.purchase.isPurchasing, restore: {
                guard preview == nil else { return }
                Task { await billing.restorePurchases() }
            })
        }
    }

    private func planCard(_ offer: BillingOffer, config: BillingPaywallConfig, style: MobilePaywallPlanCard.Style) -> some View {
        MobilePaywallPlanCard(
            offer: offer,
            style: style,
            isSelected: offer.planID == selectedOffer?.planID,
            isRecommended: offer.planID == highlightedPlan,
            isCurrent: isCurrent(offer),
            savingsPercent: config.showYearlySavings && offer.billingPeriod == .yearly
                ? offers.yearlySavingsPercent(for: offer.planID)
                : nil,
            trial: trial(for: offer),
            select: { selectedPlan = offer.planID }
        )
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(L10n.string("mobile.billing.loading", defaultValue: "Loading plans"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .accessibilityIdentifier("BillingLoading")
    }

    private func retryNotice(_ message: String) -> some View {
        VStack(spacing: 12) {
            MobilePaywallNotice(text: message, systemImage: "exclamationmark.triangle")
            Button(L10n.string("mobile.billing.retry", defaultValue: "Try Again")) {
                Task { await billing.refresh() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("BillingOffersUnavailable")
    }

    private func reportTrialShown(_ grant: BillingTrialGrant, context: BillingPaywallContext) {
        guard preview == nil, reportedTrial != grant else { return }
        reportedTrial = grant
        billing.trialOfferShown(grant, context: context)
    }

    // MARK: Derived state

    private var isCompleted: Bool {
        if case .completed = billing.purchase, preview == nil { return true }
        return false
    }

    private var isShowingOffers: Bool {
        if preview?.scenario.ineligibility != nil { return false }
        guard let account = billing.account.account else { return false }
        return (account.eligible || preview != nil) && !offers.isEmpty
    }

    /// The offers on sale; the Paywall Lab also shows them to accounts that
    /// cannot buy, so staff on web billing see the real prices.
    private var offers: [BillingOffer] {
        guard preview != nil, billing.offers.isEmpty else { return billing.offers }
        return billing.previewOffers
    }

    private var activeTrial: BillingTrialGrant? {
        preview == nil ? billing.trial.grant : previewTrial
    }

    /// The trial for this offer: the trial product replaces the plan's
    /// product in the same period.
    private func trial(for offer: BillingOffer) -> BillingTrialGrant? {
        guard let grant = activeTrial else { return nil }
        return grant.productID == offer.product.id ? grant : nil
    }

    private var currentApplePlan: BillingPlanID? {
        guard let account = billing.account.account, account.currentPlan.source == .apple else { return nil }
        return account.currentPlan.planID
    }

    private func isCurrent(_ offer: BillingOffer) -> Bool {
        guard preview == nil else { return false }
        if let productID = billing.currentAppleProductID { return productID == offer.product.id }
        return currentApplePlan == offer.planID
    }

    private var hasPeriodChoice: Bool {
        Dictionary(grouping: offers, by: \.planID).values.contains { offers in
            Set(offers.map(\.billingPeriod)).count > 1
        }
    }

    /// One offer per plan: the chosen period when the plan has it, else the
    /// period it is sold in. A granted trial replaces its plan's offer in
    /// the trial's period.
    private var visibleOffers: [BillingOffer] {
        var byPlan: [BillingPlanID: BillingOffer] = [:]
        for offer in offers {
            if let existing = byPlan[offer.planID], existing.billingPeriod == period { continue }
            byPlan[offer.planID] = offer
        }
        if let grant = activeTrial {
            let trialOffer = grant.billingOffer
            if trialOffer.billingPeriod == period || byPlan[grant.planID] == nil {
                byPlan[grant.planID] = trialOffer
            }
        }
        return byPlan.values.sorted { $0.planID < $1.planID }
    }

    /// The configured recommended plan, when it is on sale.
    private var highlightedPlan: BillingPlanID? {
        guard let planID = context?.config.highlightedPlanID else { return nil }
        return visibleOffers.contains { $0.planID == planID } ? planID : nil
    }

    private var selectedOffer: BillingOffer? {
        let visible = visibleOffers
        if let selectedPlan, let offer = visible.first(where: { $0.planID == selectedPlan }) { return offer }
        return defaultOffer
    }

    /// The plan the paywall leads with: the configured recommendation, else
    /// Pro, among the plans above the account's current one.
    private var defaultOffer: BillingOffer? {
        let visible = visibleOffers
        let current = billing.account.account?.currentPlan.planID ?? .free
        let upgrades = visible.filter { $0.planID.rank > current.rank }
        let candidates = upgrades.isEmpty ? visible : upgrades
        return candidates.first { $0.planID == highlightedPlan }
            ?? candidates.first { $0.planID == .pro }
            ?? candidates.first
    }

    /// The plan the focus layout shows large.
    private var focusOffer: BillingOffer? {
        selectedOffer
    }

    private var comparisonPlans: [BillingPlanID] {
        let sold = Set(offers.map(\.planID))
        return [.free] + [BillingPlanID.pro, .max].filter { sold.contains($0) }
    }

    private var statusMessage: String? {
        guard preview == nil else {
            return L10n.string("mobile.billing.lab.purchasesOff", defaultValue: "Purchases are off in Paywall Lab.")
        }
        return BillingStatusCopy.resultMessage(purchase: billing.purchase, restore: billing.restore)
    }
}

extension BillingPaywallPreview.Scenario {
    /// The ineligibility reason the scenario shows; nil for offer scenarios.
    var ineligibility: BillingIneligibilityReason? {
        switch self {
        case .offers, .trial: nil
        case .ineligibleWeb: .stripeSubscriptionActive
        case .ineligibleTeam: .teamBilling
        case .ineligibleUnavailable: .purchasesUnavailable
        }
    }
}
#endif
