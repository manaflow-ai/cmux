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
    private let entryPoint: BillingEntryPoint

    /// The Terms of Use page.
    static let termsURL = URL(string: "https://cmux.com/terms-of-service")!
    /// The Privacy Policy page.
    static let privacyURL = URL(string: "https://cmux.com/privacy-policy")!

    /// Creates the plans screen.
    /// - Parameter entryPoint: Where the screen was opened from, for analytics.
    public init(entryPoint: BillingEntryPoint) {
        self.entryPoint = entryPoint
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
            Section {
                if let failure = billing.offersFailure {
                    Text(BillingFailureCopy(failure: failure).message)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        } else {
            let applePlan = account.currentPlan.source == .apple ? account.currentPlan.planID : nil
            ForEach(billing.offers) { offer in
                Section {
                    MobilePlanOfferRow(
                        offer: offer,
                        isCurrent: applePlan == offer.planID,
                        isSwitch: applePlan != nil,
                        isBusy: billing.purchase.isPurchasing,
                        buy: { Task { await billing.buy(offer, entryPoint: entryPoint) } }
                    )
                }
            }
        }
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
                defaultValue: "Subscriptions renew automatically each month at the price shown until cancelled. Payment is charged to your Apple Account when you confirm the purchase. Your account is charged for renewal within 24 hours before the current period ends unless auto-renew is turned off at least 24 hours before then. Manage or cancel your subscription in your Apple Account settings."
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
                defaultValue: "You subscribe on the web. Manage your plan at cmux.com."
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
#endif
