#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
// StoreKit's sheets through CmuxMobileSystemUI.framework: linked, StoreKit
// costs the app about 1.55 s before `main` on a cold launch.
import CmuxMobileSystemUIBridge
import CmuxSpinner
import SwiftUI

/// The plans screen: current plan, App Store offers with StoreKit prices,
/// Restore Purchases, Manage Subscription, and the auto-renewal disclosure
/// with Terms and Privacy links (App Review Guideline 3.1.2).
///
/// When the server reports the account is not eligible (it pays on the web or
/// through a team, or this build's purchases would grant no plan), the screen
/// explains why and shows no purchase button and no link to web billing.
///
/// In an app whose App Store record has no subscriptions
/// (``BillingModel/offersPurchases`` false, cmux INTERNAL today) it shows the
/// current plan read-only: no offers, prices, Restore Purchases, Manage
/// Subscription or subscription terms, and no text about buying.
///
/// HIG: In-app purchase, and Lists and tables (inset-grouped sections).
///
/// Reads ``BillingModel`` from the environment:
///
/// ```swift
/// NavigationLink { MobilePlansView(entryPoint: .settings) } label: { Text("Plan") }
///     .environment(billingModel)
/// ```
public struct MobilePlansView: View {
    @Environment(BillingModel.self) private var billing
    @Environment(\.openURL) private var openURL
    /// The App Store's subscription sheet is up.
    @State private var showingManageSubscriptions = false
    /// The subscription the open refund sheet is for, fixed at the tap so a
    /// reload while the sheet is up cannot change or drop it.
    @State private var refundTarget: RefundTarget?
    /// The Monthly/Yearly choice.
    @State private var period: BillingPeriod
    private let entryPoint: BillingEntryPoint

    /// The Terms of Use page.
    static let termsURL = URL(string: "https://cmux.com/terms-of-service")!
    /// The Privacy Policy page.
    static let privacyURL = URL(string: "https://cmux.com/privacy-policy")!

    /// Creates the plans screen.
    /// - Parameters:
    ///   - entryPoint: Where the screen was opened from, for analytics.
    ///   - initialPeriod: The billing period selected first. Yearly by
    ///     default, as on cmux.com/pricing.
    public init(entryPoint: BillingEntryPoint, initialPeriod: BillingPeriod = .yearly) {
        self.entryPoint = entryPoint
        _period = State(initialValue: initialPeriod)
    }

    public var body: some View {
        List {
            currentPlanSection
            accountContent
            resultSection
            actionsSection
            legalSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.billing.title", defaultValue: "Plans"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            billing.paywallViewed(entryPoint: entryPoint)
            await billing.refresh()
        }
        .refreshable { await billing.refresh() }
        // StoreKit's refund sheet keeps the transaction ID it was first built
        // with, so a sheet built before the tap asked Apple about transaction 0
        // and failed (Sandbox run on a Mac, 2026-11-17). The host is created
        // only once the target exists, keyed by it, and presents on appear.
        .background {
            if let target = refundTarget {
                RefundRequestHost(target: target) { outcome in
                    refundTarget = nil
                    billing.refundRequestFinished(productID: target.productID, result: outcome)
                }
                .id(target)
            }
        }
        .onDisappear { billing.dismissResult() }
        .accessibilityIdentifier("BillingPlansView")
    }

    @ViewBuilder
    private var currentPlanSection: some View {
        if let account = billing.account.account {
            Section {
                LabeledContent(
                    L10n.string("mobile.billing.currentPlan", defaultValue: "Current plan"),
                    value: BillingPlanCopy(planID: account.currentPlan.planID).name
                )
                .accessibilityIdentifier("BillingCurrentPlan")
            } footer: {
                let sourceText = sourceText(account.currentPlan.source)
                if billing.paymentPastDue || sourceText != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        if billing.paymentPastDue {
                            PaymentPastDueNotice()
                                .accessibilityIdentifier("BillingPaymentPastDue")
                        }
                        if let sourceText {
                            Text(sourceText)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var accountContent: some View {
        switch billing.account {
        case .idle, .loading:
            Section {
                HStack(spacing: 12) {
                    CmuxSpinner()
                    Text(L10n.string("mobile.billing.loading", defaultValue: "Loading plans"))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("BillingLoading")
            }
        case .failed(let failure):
            Section {
                Text(BillingFailureCopy(failure: failure).message)
                    .foregroundStyle(.secondary)
                Button(L10n.string("mobile.billing.retry", defaultValue: "Try Again")) {
                    Task { await billing.refresh() }
                }
            }
            .accessibilityIdentifier("BillingLoadFailed")
        case .loaded(let account):
            if !billing.offersPurchases {
                // Read-only: the current plan section above is the whole screen.
                EmptyView()
            } else if account.eligible {
                offersSection(account)
            } else {
                Section {
                    Text(ineligibleText(account.reason))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("BillingIneligible")
                }
                // Nothing is on sale here, but the plans are still listed.
                // visible-only: at most 3 distinct plan ids (Go, Pro, Max); a plan id is its own stable identity.
                ForEach(account.catalogPlanIDs, id: \.self) { planID in
                    Section {
                        MobilePlanCatalogRow(planID: planID, isCurrent: planID == account.currentPlan.planID)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func offersSection(_ account: BillingAccount) -> some View {
        if billing.offers.isEmpty {
            if let failure = billing.offersFailure {
                Section {
                    Text(BillingFailureCopy(failure: failure).message)
                        .foregroundStyle(.secondary)
                    Button(L10n.string("mobile.billing.retry", defaultValue: "Try Again")) {
                        Task { await billing.refresh() }
                    }
                }
                .accessibilityIdentifier("BillingOffersUnavailable")
            } else {
                Section {
                    CmuxSpinner()
                }
                .accessibilityIdentifier("BillingOffersLoading")
            }
        } else {
            let applePlan = account.currentPlan.source == .apple ? account.currentPlan.planID : nil
            if hasPeriodChoice {
                Section {
                    Picker(L10n.string("mobile.billing.period", defaultValue: "Billing period"), selection: $period) {
                        Text(L10n.string("mobile.billing.period.monthly", defaultValue: "Monthly"))
                            .tag(BillingPeriod.monthly)
                        Text(L10n.string("mobile.billing.period.yearly", defaultValue: "Yearly"))
                            .tag(BillingPeriod.yearly)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("BillingPeriodPicker")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            ForEach(visibleOffers) { offer in
                Section {
                    MobilePlanOfferRow(
                        offer: offer,
                        isCurrent: isCurrent(offer, applePlan: applePlan),
                        isSwitch: applePlan != nil,
                        isBusy: billing.purchase.isPurchasing,
                        buy: { Task { await billing.buy(offer, entryPoint: entryPoint) } }
                    )
                }
            }
        }
    }

    /// True when at least one plan is sold both monthly and yearly.
    private var hasPeriodChoice: Bool {
        Dictionary(grouping: billing.offers, by: \.planID).values.contains { offers in
            Set(offers.map(\.billingPeriod)).count > 1
        }
    }

    /// The offer is the active App Store subscription. With the active
    /// product known, only that product is current, so the other period of
    /// the same plan stays buyable as a switch; otherwise the plan decides.
    private func isCurrent(_ offer: BillingOffer, applePlan: BillingPlanID?) -> Bool {
        if let productID = billing.currentAppleProductID { return productID == offer.product.id }
        return applePlan == offer.planID
    }

    /// One offer per plan: the chosen period when the plan has it, else the
    /// period the plan is sold in (Go is monthly only).
    private var visibleOffers: [BillingOffer] {
        var byPlan: [BillingPlanID: BillingOffer] = [:]
        for offer in billing.offers {
            if let existing = byPlan[offer.planID], existing.billingPeriod == period { continue }
            byPlan[offer.planID] = offer
        }
        return byPlan.values.sorted { $0.planID < $1.planID }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let message = resultMessage {
            Section {
                HStack(spacing: 12) {
                    if billing.purchase.isPurchasing || billing.restore == .restoring {
                        CmuxSpinner()
                    }
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("BillingResult")
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if billing.offersPurchases, let account = billing.account.account {
            Section {
                Button(L10n.string("mobile.billing.restore", defaultValue: "Restore Purchases")) {
                    Task { await billing.restorePurchases() }
                }
                .disabled(billing.restore == .restoring || billing.purchase.isPurchasing)
                .accessibilityIdentifier("BillingRestore")
                if account.currentPlan.source == .apple {
                    Button(L10n.string("mobile.billing.manage", defaultValue: "Manage Subscription")) {
                        switch BillingManageSubscriptionsRoute.route(isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac) {
                        case .storeKitSheet:
                            showManageSubscriptions()
                        case .appStorePage(let url):
                            openURL(url) { accepted in
                                // No App Store handler took the link: the web page still works.
                                if !accepted { openURL(BillingManageSubscriptionsRoute.webSubscriptionsURL) }
                            }
                        }
                    }
                    .accessibilityIdentifier("BillingManage")
                    if let productID = billing.currentAppleProductID,
                       let transactionID = billing.currentAppleTransactionID {
                        Button(L10n.string("mobile.billing.refund", defaultValue: "Request a Refund")) {
                            refundTarget = RefundTarget(productID: productID, transactionID: transactionID)
                            billing.refundRequestOpened(productID: productID)
                        }
                        .accessibilityIdentifier("BillingRefund")
                    }
                }
            }
        }
    }

    /// `AppStore.showManageSubscriptions(in:)`; Apple's web subscriptions
    /// page when the framework did not load or no window scene is in front.
    private func showManageSubscriptions() {
        guard !showingManageSubscriptions else { return }
        guard let provider = SystemUI.provider, let scene = SystemUI.foregroundScene else {
            openURL(BillingManageSubscriptionsRoute.webSubscriptionsURL)
            return
        }
        showingManageSubscriptions = true
        provider.showManageSubscriptions(in: scene) { _ in
            showingManageSubscriptions = false
        }
    }

    @ViewBuilder
    private var legalSection: some View {
        if billing.offersPurchases {
            legalLinks
        }
    }

    private var legalLinks: some View {
        Section {
            Link(L10n.string("mobile.billing.terms", defaultValue: "Terms of Use"), destination: Self.termsURL)
            Link(L10n.string("mobile.billing.privacy", defaultValue: "Privacy Policy"), destination: Self.privacyURL)
        } footer: {
            Text(L10n.string(
                "mobile.billing.disclosure",
                defaultValue: "Subscriptions renew automatically at the end of each month or year, as shown, at the price shown until cancelled. Payment is charged to your Apple Account when you confirm the purchase. Your account is charged for renewal within 24 hours before the current period ends unless auto-renew is turned off at least 24 hours before then. Manage or cancel your subscription in your Apple Account settings."
            ))
        }
    }

    private var resultMessage: String? {
        switch billing.restore {
        case .restoring:
            return L10n.string("mobile.billing.restoring", defaultValue: "Restoring purchases")
        case .completed(let count):
            return count > 0
                ? L10n.string("mobile.billing.restored", defaultValue: "Your purchases were restored.")
                : L10n.string("mobile.billing.restoredNone", defaultValue: "No active App Store subscription was found.")
        case .failed(let failure):
            return BillingFailureCopy(failure: failure).message
        case .idle:
            break
        }
        switch billing.purchase {
        case .idle:
            return nil
        case .purchasing:
            return L10n.string("mobile.billing.purchasing", defaultValue: "Completing your purchase")
        case .pending:
            return L10n.string(
                "mobile.billing.pending",
                defaultValue: "Your purchase is waiting for approval. Your plan updates when it is approved."
            )
        case .completed(let planID):
            return String(
                format: L10n.string("mobile.billing.completed", defaultValue: "You're on %@ now."),
                BillingPlanCopy(planID: planID).name
            )
        case .awaitingServer:
            return L10n.string(
                "mobile.billing.awaitingServer",
                defaultValue: "Purchase complete. Your plan updates as soon as cmux confirms it. You don't need to buy again."
            )
        case .failed(let failure):
            return BillingFailureCopy(failure: failure).message
        }
    }

    private func sourceText(_ source: BillingPlanSource) -> String? {
        switch source {
        case .apple:
            L10n.string("mobile.billing.source.apple", defaultValue: "Billed through the App Store.")
        case .stripe:
            L10n.string("mobile.billing.source.web", defaultValue: "Billed on the web.")
        case .none, .other:
            nil
        }
    }

    private func ineligibleText(_ reason: BillingIneligibilityReason?) -> String {
        switch reason {
        case .stripeSubscriptionActive:
            // Plain text on purpose: the App Store build must not link to web
            // billing (App Review Guideline 3.1.1).
            L10n.string(
                "mobile.billing.ineligible.web",
                defaultValue: "You subscribe on the web."
            )
        case .teamBilling:
            L10n.string(
                "mobile.billing.ineligible.team",
                defaultValue: "Your team admin manages billing for this account."
            )
        case .purchasesUnavailable:
            L10n.string(
                "mobile.billing.ineligible.unavailable",
                defaultValue: "Plans can't be bought in this version of the app."
            )
        case .other, .none:
            L10n.string(
                "mobile.billing.ineligible.other",
                defaultValue: "Plans can't be bought in the app for this account."
            )
        }
    }
}

/// The subscription a refund request is for.
private struct RefundTarget: Hashable {
    let productID: String
    let transactionID: UInt64
    /// One per tap, so a sheet StoreKit never finished cannot block the next tap.
    let attempt = UUID()
}

/// Presents StoreKit's refund sheet (`Transaction.beginRefundRequest(for:in:)`)
/// for one transaction, started only after the person asked for it so the
/// sheet never sees a placeholder ID. Reports `error` when the framework did
/// not load or no window scene is in front.
private struct RefundRequestHost: View {
    let target: RefundTarget
    let finished: (String) -> Void
    @State private var started = false

    var body: some View {
        Color.clear
            .onAppear {
                guard !started else { return }
                started = true
                guard let provider = SystemUI.provider, let scene = SystemUI.foregroundScene else {
                    finished("error")
                    return
                }
                provider.beginRefundRequest(transactionID: target.transactionID, in: scene) { result in
                    let outcome: String
                    switch result {
                    case .success: outcome = "success"
                    case .userCancelled: outcome = "userCancelled"
                    case .error: outcome = "error"
                    }
                    finished(outcome)
                }
            }
    }
}
#endif
