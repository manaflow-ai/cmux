#if os(iOS) && DEBUG
import CmuxMobileBilling
import Foundation

/// DEBUG-only screenshot rig for Settings → Plan (CMUX-38): the real
/// ``BillingModel`` and plans screen over an in-memory server and App Store,
/// so the fleet's `shots` mode can capture every state without an App Store
/// account. Compiled out of every shipping configuration.
///
/// `CMUX_MOBILE_BILLING_DEMO` picks the state: `free` (Free, Go/Pro/Max
/// offers), `pro` (an App Store Pro subscriber), `stripe` (pays on the web: no
/// purchase buttons), `team` (team billing), `unavailable` (the server sells
/// nothing to this bundle, today's state for cmux NEXT). `CMUX_MOBILE_BILLING_DEMO_OPEN=1`
/// opens the plans screen at launch. Prices are the server's USD list prices
/// (`web/services/billing/apple/config.ts` `APPLE_USD_LIST_PRICE`, yearly at 9.6×).
struct BillingDemo {
    let state: String

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let state = environment["CMUX_MOBILE_BILLING_DEMO"], !state.isEmpty else { return nil }
        self.state = state
    }

    static var opensPlans: Bool { ProcessInfo.processInfo.environment["CMUX_MOBILE_BILLING_DEMO_OPEN"] == "1" }

    @MainActor
    func makeModel(bundleIdentifier: String) -> BillingModel {
        let server = DemoBillingServer(state: state, bundleIdentifier: bundleIdentifier)
        return BillingModel(api: server, store: DemoStoreKit(bundleIdentifier: bundleIdentifier), analytics: nil)
    }
}

/// The server side of the rig: the account token and, after a demo purchase, the plan it grants.
private actor DemoBillingServer: BillingAPI {
    private let state: String
    private let bundleIdentifier: String
    private var plan: BillingCurrentPlan

    init(state: String, bundleIdentifier: String) {
        self.state = state
        self.bundleIdentifier = bundleIdentifier
        switch state {
        case "pro": plan = BillingCurrentPlan(planID: .pro, source: .apple)
        case "stripe": plan = BillingCurrentPlan(planID: .pro, source: .stripe)
        default: plan = BillingCurrentPlan(planID: .free, source: .none)
        }
    }

    func accountToken() async throws -> BillingAccount {
        let products = state == "unavailable" ? [] : [BillingPlanID.go, .pro, .max].flatMap { plan in
            BillingPeriod.allCases.map { period in
                BillingProductReference(productID: "\(bundleIdentifier).\(plan.rawValue).\(period.rawValue)",
                                        planID: plan, billingPeriod: period)
            }
        }
        let reason: BillingIneligibilityReason? = switch state {
        case "stripe": .stripeSubscriptionActive
        case "team": .teamBilling
        default: nil
        }
        return BillingAccount(appAccountToken: UUID(),
                              eligible: reason == nil, reason: reason, currentPlan: plan, products: products)
    }

    func submitTransaction(signedTransactionInfo: String) async throws -> BillingTransactionReceipt {
        let planID = BillingPlanID(rawValue: signedTransactionInfo.split(separator: ".").dropLast().last.map(String.init) ?? "pro")
        plan = BillingCurrentPlan(planID: planID, source: .apple)
        return BillingTransactionReceipt(planID: planID, status: "active", expiresAt: nil)
    }
}

/// The App Store side of the rig: StoreKit-shaped products at the list prices, and purchases that complete.
private struct DemoStoreKit: StoreKitClient {
    let bundleIdentifier: String
    /// Server list prices: monthly, and yearly at 9.6× (`appleUsdListPrice`).
    private static let prices: [String: (name: String, monthly: String, yearly: String)] = [
        "go": ("Go", "14.99", "143.90"), "pro": ("Pro", "74.99", "719.90"), "max": ("Max", "299.99", "2879.90"),
    ]

    func products(for ids: [String]) async throws -> [StoreProduct] {
        ids.compactMap { id in
            let parts = id.split(separator: ".").map(String.init)
            guard parts.count >= 2, let entry = Self.prices[parts[parts.count - 2]],
                  let period = BillingPeriod(productID: id),
                  let price = Decimal(string: period == .yearly ? entry.yearly : entry.monthly) else { return nil }
            return StoreProduct(
                id: id,
                displayName: "cmux \(entry.name)",
                productDescription: "cmux \(entry.name), \(period.rawValue)",
                displayPrice: Self.usd(price),
                periodUnitName: period == .yearly ? "year" : "month",
                price: price,
                currencyCode: "USD",
                monthlyEquivalentDisplayPrice: period == .yearly ? Self.usd(price / 12) : nil
            )
        }
    }

    func purchase(productID: String, appAccountToken: UUID) async throws -> StorePurchaseResult {
        .completed(.verified(StoreTransaction(id: 38, productID: productID, jwsRepresentation: productID,
                                              appAccountToken: appAccountToken, environment: "Xcode")))
    }

    func transactionUpdates() -> AsyncStream<StoreTransactionVerification> { AsyncStream { _ in } }
    func unfinishedTransactions() async -> [StoreTransactionVerification] { [] }
    func currentEntitlements() async -> [StoreTransactionVerification] { [] }
    func syncWithAppStore() async throws {}
    func storefrontCountryCode() async -> String? { "USA" }
    func finish(transactionID: UInt64) async {}

    private static func usd(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}
#endif

#if os(iOS) && DEBUG
import CmuxMobileBillingUI
import SwiftUI

/// Opens the plans screen at launch for the rig (`CMUX_MOBILE_BILLING_DEMO_OPEN=1`).
struct BillingDemoSheet: ViewModifier {
    let billing: BillingModel?
    @State private var shown = BillingDemo.opensPlans

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { shown && billing != nil }, set: { shown = $0 })) {
            if let billing { MobilePlansSheet(entryPoint: .settings).environment(billing) }
        }
    }
}
#endif
