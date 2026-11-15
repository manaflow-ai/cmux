#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI
import StoreKit

/// The plans screen: current plan, App Store offers with StoreKit prices,
/// Restore Purchases, Manage Subscription, and the auto-renewal disclosure
/// with Terms and Privacy links (App Review Guideline 3.1.2).
///
/// When the server reports the account is not eligible (it pays on the web or
/// through a team, or this build's purchases would grant no plan), the screen
/// explains why and shows no purchase button and no link to web billing.
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
    @State private var showingManageSubscriptions = false
    @State private var showingRefundRequest = false
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
        .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
        .refundRequestSheet(
            for: refundTarget?.transactionID ?? 0,
            isPresented: $showingRefundRequest
        ) { result in
            guard let target = refundTarget else { return }
            refundTarget = nil
            let outcome: String
            switch result {
            case .success(.success): outcome = "success"
            case .success(.userCancelled): outcome = "userCancelled"
            default: outcome = "error"
            }
            billing.refundRequestFinished(productID: target.productID, result: outcome)
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
                if let sourceText = sourceText(account.currentPlan.source) {
                    Text(sourceText)
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
                    ProgressView()
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
            if account.eligible {
                offersSection(account)
            } else {
                Section {
                    Text(ineligibleText(account.reason))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("BillingIneligible")
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
                    ProgressView()
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
                        ProgressView()
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
        if let account = billing.account.account {
            Section {
                Button(L10n.string("mobile.billing.restore", defaultValue: "Restore Purchases")) {
                    Task { await billing.restorePurchases() }
                }
                .disabled(billing.restore == .restoring || billing.purchase.isPurchasing)
                .accessibilityIdentifier("BillingRestore")
                if account.currentPlan.source == .apple {
                    Button(L10n.string("mobile.billing.manage", defaultValue: "Manage Subscription")) {
                        showingManageSubscriptions = true
                    }
                    .accessibilityIdentifier("BillingManage")
                    if let productID = billing.currentAppleProductID,
                       let transactionID = billing.currentAppleTransactionID {
                        Button(L10n.string("mobile.billing.refund", defaultValue: "Request a Refund")) {
                            refundTarget = RefundTarget(productID: productID, transactionID: transactionID)
                            billing.refundRequestOpened(productID: productID)
                            showingRefundRequest = true
                        }
                        .accessibilityIdentifier("BillingRefund")
                    }
                }
            }
        }
    }

    private var legalSection: some View {
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
private struct RefundTarget: Equatable {
    let productID: String
    let transactionID: UInt64
}
#endif
