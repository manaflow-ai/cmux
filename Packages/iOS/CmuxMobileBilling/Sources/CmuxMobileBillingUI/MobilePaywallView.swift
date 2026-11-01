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
    /// The configured default period; a plan sold in it starts there.
    @State private var period: BillingPeriod = .yearly
    /// Each plan's own period choice. The period belongs to the plan, not
    /// the screen: Max without a yearly product never shows a toggle.
    @State private var planPeriods: [BillingPlanID: BillingPeriod] = [:]
    @State private var selectedPlan: BillingPlanID?
    @State private var showsAllPlans = false
    @State private var appearedAt: ContinuousClock.Instant?
    @State private var reachedPurchase = false
    @State private var dismissReported = false
    @State private var reportedTrial: BillingTrialGrant?
    /// The Paywall Lab's trial, built from real StoreKit prices.
    @State private var previewTrial: BillingTrialGrant?
    /// "See Max" in the checklist layout switches to the plan tabs.
    @State private var layoutOverride: BillingPaywallLayout?
    /// False once the user declined notifications: the trial timeline then
    /// drops the reminder it could not send.
    @State private var reminderAllowed = false

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
            VStack(spacing: 0) {
                if let context, effectiveLayout == .hero, !isCompleted, isShowingOffers {
                    MobilePaywallHeroHeader(
                        headline: context.config.headline(for: context.entryPoint),
                        subheadline: context.config.subheadline
                    )
                }
                VStack(alignment: .leading, spacing: 24) {
                    if let context {
                        if case .completed(let planID) = billing.purchase, preview == nil {
                            MobilePaywallSuccess(planID: planID, done: { dismiss() })
                        } else {
                            if effectiveLayout != .hero || !isShowingOffers {
                                MobilePaywallHeader(config: context.config, entryPoint: context.entryPoint)
                            }
                            content(context)
                        }
                    } else {
                        loadingRow
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, effectiveLayout == .hero && isShowingOffers ? 24 : 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: effectiveLayout == .hero && isShowingOffers ? .top : [])
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let context, let offer = selectedOffer, isShowingOffers, !isCompleted, effectiveLayout != .specList {
                MobilePaywallPurchaseBar(
                    offer: offer,
                    config: context.config,
                    trial: trial(for: offer),
                    isCurrent: isCurrent(offer),
                    isSwitch: currentApplePlan != nil,
                    isBusy: billing.purchase.isPurchasing,
                    isPreview: preview != nil,
                    statusMessage: statusMessage,
                    titleOverride: ctaTitleOverride(offer),
                    renewalOverride: renewalOverride,
                    buy: { buy(offer, context: context) }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    if effectiveLayout == .specList {
                        Text(L10n.string("mobile.billing.done", defaultValue: "Done"))
                    } else {
                        Image(systemName: "xmark")
                    }
                }
                .accessibilityLabel(effectiveLayout == .specList
                    ? L10n.string("mobile.billing.done", defaultValue: "Done")
                    : L10n.string("mobile.billing.paywall.close", defaultValue: "Close"))
                .accessibilityIdentifier("BillingPaywallClose")
            }
            if effectiveLayout.restoreAtTop, isShowingOffers, !isCompleted {
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.string("mobile.billing.restoreShort", defaultValue: "Restore")) {
                        guard preview == nil else { return }
                        Task { await billing.restorePurchases() }
                    }
                    .disabled(billing.restore == .restoring || billing.purchase.isPurchasing)
                    .accessibilityIdentifier("BillingPaywallRestoreTop")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(effectiveLayout == .hero && isShowingOffers ? .dark : nil, for: .navigationBar)
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
            reminderAllowed = await BillingTrialReminder().canRemind()
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
        reminderAllowed = await BillingTrialReminder().canRemind()
        if wasLoaded { await billing.refresh() }
        await billing.prepareTrial()
        guard !Task.isCancelled else { return }
        if let grant = billing.trial.grant {
            // Lead with the trial: select its plan and period.
            planPeriods[grant.planID] = grant.billingOffer.billingPeriod
            selectedPlan = grant.planID
        }
    }

    private func apply(_ fixed: BillingPaywallContext) {
        context = fixed
        period = fixed.config.defaultBillingPeriod
        planPeriods = [:]
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
        planPeriods[.pro] = .monthly
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
        let trial = trial(for: offer)
        let promisesReminder = trial != nil && effectiveLayout == .trialTimeline && reminderAllowed
        Task {
            if promisesReminder {
                // Ask in context: the timeline promised this reminder.
                reminderAllowed = await BillingTrialReminder().requestIfNeeded()
            }
            let charged = await billing.buy(offer, context: context, trial: trial)
            // Decided from this purchase's own result, not the shared phase,
            // which a close during the purchase may already have cleared.
            guard charged, let trial, promisesReminder, reminderAllowed else { return }
            await BillingTrialReminder().schedule(grant: trial)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ context: BillingPaywallContext) -> some View {
        if let scenario = preview?.scenario, let reason = scenario.ineligibility {
            MobilePaywallNotice(text: BillingIneligibilityCopy(reason: reason).message, systemImage: "info.circle")
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
                    MobilePaywallNotice(text: BillingIneligibilityCopy(reason: account.reason).message, systemImage: "info.circle")
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
            // At accessibility sizes the selling points give way so the plans
            // and prices stay above the fold.
            if !config.bullets.isEmpty, effectiveLayout.showsBullets, !dynamicTypeSize.isAccessibilitySize {
                MobilePaywallBullets(bullets: config.bullets)
            }
            if showsGlobalPeriodPicker {
                MobilePaywallPeriodPicker(
                    period: Binding(get: { period }, set: { period = $0; planPeriods = [:] }),
                    savingsPercent: config.showYearlySavings ? offers.bestYearlySavingsPercent : nil
                )
            }
            switch effectiveLayout {
            case .checklist:
                MobilePaywallChecklist()
                if offers.contains(where: { $0.planID == .max }) {
                    Button {
                        withAnimation(.snappy) {
                            layoutOverride = .planTabs
                            selectedPlan = .max
                        }
                    } label: {
                        Text(L10n.string("mobile.billing.checklist.seeMax", defaultValue: "See Max"))
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("BillingPaywallSeeMax")
                }
            case .planTabs:
                MobilePaywallPlanTabs(
                    plans: tabPlans,
                    selectedPlan: Binding(
                        get: { selectedOffer.map(\.planID) ?? .pro },
                        set: { selectedPlan = $0 }
                    ),
                    offers: periodOffers(for: selectedOffer?.planID ?? .pro),
                    period: periodBinding(for: selectedOffer?.planID ?? .pro),
                    savingsPercent: config.showYearlySavings
                        ? offers.yearlySavingsPercent(for: selectedOffer?.planID ?? .pro)
                        : nil
                )
            case .hero:
                MobilePaywallHeroBenefits(bullets: config.bullets)
                MobilePaywallTierSelector(
                    offers: visibleOffers.filter { $0.planID == .pro || $0.planID == .max }.sorted { $0.planID < $1.planID },
                    selectedPlan: selectedOffer?.planID,
                    select: { selectedPlan = $0 }
                )
                if let plan = selectedOffer?.planID, plansWithBothPeriods.contains(plan) {
                    MobilePaywallPeriodPicker(
                        period: periodBinding(for: plan),
                        savingsPercent: config.showYearlySavings ? offers.yearlySavingsPercent(for: plan) : nil
                    )
                }
            case .specList:
                MobilePaywallSpecList(
                    rows: visibleOffers.map { offer in
                        MobilePaywallSpecList.Row(
                            offer: offer,
                            facts: billing.planFacts(offer.planID),
                            specLines: context.config.planSpecs[offer.planID.rawValue] ?? [],
                            isCurrent: isCurrent(offer),
                            trial: trial(for: offer),
                            period: plansWithBothPeriods.contains(offer.planID) ? periodBinding(for: offer.planID) : nil
                        )
                    },
                    isBusy: billing.purchase.isPurchasing,
                    isPreview: preview != nil,
                    buy: { offer in
                        selectedPlan = offer.planID
                        buy(offer, context: context)
                    }
                )
            case .trialTimeline:
                if let grant = activeTrial {
                    MobilePaywallTrialTimeline(grant: grant, showsReminder: reminderAllowed)
                }
            case .cards:
                VStack(spacing: 12) {
                    ForEach(visibleOffers) { offer in
                        planCard(offer, config: config, style: .standard)
                    }
                }
            case .comparison:
                // The plans and prices first, so they sit above the fold;
                // the table explains them below.
                VStack(spacing: 8) {
                    ForEach(visibleOffers) { offer in
                        planCard(offer, config: config, style: .compact)
                    }
                }
                MobilePaywallComparison(plans: comparisonPlans, highlighted: highlightedPlan, accessibilityLayout: dynamicTypeSize.isAccessibilitySize)
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
            // The terms sit with the trial's own button: in specList that is
            // its row, not the selected plan.
            if let trial = effectiveLayout == .specList
                ? visibleOffers.lazy.compactMap({ trial(for: $0) }).first
                : selectedOffer.flatMap(trial(for:)) {
                MobilePaywallTrialTerms(grant: trial)
                    .onAppear { reportTrialShown(trial, context: context) }
            }
            if effectiveLayout == .specList, let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("BillingResult")
            }
            MobilePaywallLegal(showsRestore: !effectiveLayout.restoreAtTop, isBusy: billing.restore == .restoring || billing.purchase.isPurchasing, restore: {
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
            period: !showsGlobalPeriodPicker && plansWithBothPeriods.contains(offer.planID)
                ? periodBinding(for: offer.planID)
                : nil,
            alternateOffer: offers.first { $0.planID == offer.planID && $0.billingPeriod != offer.billingPeriod },
            alternateSavingsPercent: config.showYearlySavings ? offers.yearlySavingsPercent(for: offer.planID) : nil,
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

    /// The plans sold both monthly and yearly.
    private var plansWithBothPeriods: Set<BillingPlanID> {
        Set(Dictionary(grouping: offers, by: \.planID).filter { Set($0.value.map(\.billingPeriod)).count > 1 }.keys)
    }

    /// One Monthly/Yearly control for the whole screen, only when every paid
    /// plan on it has both periods; otherwise each plan carries its own.
    private var showsGlobalPeriodPicker: Bool {
        guard effectiveLayout.showsPeriodPicker else { return false }
        let paid = Set(offers.map(\.planID)).subtracting([.free])
        return !paid.isEmpty && paid.isSubset(of: plansWithBothPeriods)
    }

    /// The period a plan shows: its own choice, else the configured default
    /// when the plan is sold in it, else the period it is sold in.
    private func periodFor(_ plan: BillingPlanID) -> BillingPeriod {
        if let chosen = planPeriods[plan] { return chosen }
        let sold = Set(offers.filter { $0.planID == plan }.map(\.billingPeriod))
        return sold.contains(period) || sold.isEmpty ? period : (sold.first ?? period)
    }

    private func periodBinding(for plan: BillingPlanID) -> Binding<BillingPeriod> {
        Binding(
            get: { periodFor(plan) },
            set: { newValue in
                planPeriods[plan] = newValue
                selectedPlan = plan
            }
        )
    }

    /// One offer per plan: the chosen period when the plan has it, else the
    /// period it is sold in. A granted trial replaces its plan's offer in
    /// the trial's period.
    private var visibleOffers: [BillingOffer] {
        var byPlan: [BillingPlanID: BillingOffer] = [:]
        for offer in offers {
            if let existing = byPlan[offer.planID], existing.billingPeriod == periodFor(offer.planID) { continue }
            byPlan[offer.planID] = offer
        }
        if let grant = activeTrial {
            let trialOffer = grant.billingOffer
            if trialOffer.billingPeriod == periodFor(grant.planID) || byPlan[grant.planID] == nil {
                byPlan[grant.planID] = trialOffer
            }
        }
        // The recommended plan leads, then the rest from the largest down,
        // so the plans worth buying are above the fold.
        let lead = context?.config.highlightedPlanID
        return byPlan.values.sorted { lhs, rhs in
            if (lhs.planID == lead) != (rhs.planID == lead) { return lhs.planID == lead }
            return rhs.planID < lhs.planID
        }
    }

    /// The configured recommended plan, when it is on sale.
    private var highlightedPlan: BillingPlanID? {
        guard let planID = context?.config.highlightedPlanID else { return nil }
        return visibleOffers.contains { $0.planID == planID } ? planID : nil
    }

    private var selectedOffer: BillingOffer? {
        let visible = visibleOffers
        // The checklist compares Free with Pro, so its button buys Pro.
        if effectiveLayout == .checklist, let pro = visible.first(where: { $0.planID == .pro }) { return pro }
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

    /// The layout on screen: the configured one, "See Max"'s plan tabs, or
    /// cards for a trial timeline without a granted trial.
    private var effectiveLayout: BillingPaywallLayout {
        if let layoutOverride { return layoutOverride }
        guard let layout = context?.config.layout else { return .cards }
        if layout == .trialTimeline, activeTrial == nil { return .cards }
        return layout
    }

    /// Pro and Max, as sold.
    private var tabPlans: [BillingPlanID] {
        let sold = Set(offers.map(\.planID))
        return [BillingPlanID.pro, .max].filter { sold.contains($0) }
    }

    /// One plan's offers, one per period; a granted trial replaces its
    /// period's product.
    private func periodOffers(for plan: BillingPlanID) -> [BillingOffer] {
        var byPeriod: [BillingPeriod: BillingOffer] = [:]
        for offer in offers where offer.planID == plan { byPeriod[offer.billingPeriod] = offer }
        if let grant = activeTrial, grant.planID == plan { byPeriod[grant.billingOffer.billingPeriod] = grant.billingOffer }
        return Array(byPeriod.values)
    }

    private func ctaTitleOverride(_ offer: BillingOffer) -> String? {
        switch effectiveLayout {
        case .checklist where trial(for: offer) == nil:
            return String(
                format: L10n.string("mobile.billing.checklist.cta", defaultValue: "Upgrade for %@"),
                offer.priceText
            )
        case .planTabs where trial(for: offer) == nil:
            return String(
                format: L10n.string("mobile.billing.paywall.subscribeFor", defaultValue: "Subscribe for %@"),
                offer.priceText
            )
        case .trialTimeline:
            guard let trial = trial(for: offer) else { return nil }
            return trial.offer.totalDays == 7
                ? L10n.string("mobile.billing.timeline.cta", defaultValue: "Start My Free Week")
                : nil
        default:
            return nil
        }
    }

    private var renewalOverride: String? {
        guard effectiveLayout == .checklist, let offer = selectedOffer, trial(for: offer) == nil else { return nil }
        return L10n.string("mobile.billing.checklist.renewal", defaultValue: "Auto-renews. Cancel anytime in Settings.")
    }

    private var comparisonPlans: [BillingPlanID] {
        // Paid plans first, the recommended one leading; Free last, for
        // contrast.
        let sold = Set(offers.map(\.planID))
        var paid = [BillingPlanID.pro, .max].filter { sold.contains($0) }
        if let lead = highlightedPlan, let index = paid.firstIndex(of: lead) {
            paid.remove(at: index)
            paid.insert(lead, at: 0)
        }
        return paid + [.free]
    }

    private var statusMessage: String? {
        guard preview == nil else {
            return L10n.string("mobile.billing.lab.purchasesOff", defaultValue: "Purchases are off in Paywall Lab.")
        }
        return BillingStatusCopy(purchase: billing.purchase, restore: billing.restore).resultMessage
    }
}

extension BillingPaywallLayout {
    /// Layouts with the Monthly/Yearly picker above the plans.
    var showsPeriodPicker: Bool {
        switch self {
        case .cards, .comparison, .focus: true
        case .checklist, .planTabs, .hero, .trialTimeline, .specList: false
        }
    }

    /// Layouts that list the configured bullets above the plans (hero
    /// shows them as its benefit rows).
    var showsBullets: Bool {
        switch self {
        case .hero, .checklist, .specList: false
        default: true
        }
    }

    /// Layouts with Restore at the top right instead of the bottom row.
    var restoreAtTop: Bool {
        switch self {
        case .planTabs, .hero: true
        default: false
        }
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
