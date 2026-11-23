import Foundation
import Testing
@testable import CmuxMobileBilling

@Suite struct BillingPurchaseAvailabilityTests {
    static let internalBundle = "dev.cmux.app.internal"
    static let offer = BillingOffer(planID: .pro, product: BillingFixtures.product(.pro, price: "$74.99"))
    static let eligible = BillingAccountState.loaded(BillingFixtures.account())
    static let unavailable = BillingAccountState.loaded(
        BillingFixtures.account(eligible: false, reason: .purchasesUnavailable)
    )
    static let everyState: [BillingAccountState] = [
        .idle, .loading, .failed(.network), eligible, unavailable,
        .loaded(BillingFixtures.account(eligible: false, reason: .stripeSubscriptionActive)),
        .loaded(BillingFixtures.account(eligible: false, reason: .teamBilling)),
    ]

    /// The App Store app, the beta, dev builds and a host that named no bundle
    /// offer purchases in every account state, as before the rule existed.
    @Test(arguments: ["com.cmux.app", "dev.cmux.app.beta", "dev.cmux.mobile", "dev.cmux.mobile.prod", nil] as [String?])
    func appsWithSubscriptionsAlwaysOffer(bundle: String?) {
        for state in Self.everyState {
            for offers in [[], [Self.offer]] {
                #expect(BillingPurchaseAvailability.offersPurchases(bundleIdentifier: bundle, account: state, offers: offers))
            }
        }
    }

    /// cmux INTERNAL today: the server answers `purchases_unavailable` and
    /// lists nothing, so nothing is offered, in any state.
    @Test func internalOffersNothingToday() {
        #expect(BillingPurchaseAvailability.appsWithoutSubscriptions == [Self.internalBundle])
        for state in Self.everyState where state != Self.eligible {
            #expect(!BillingPurchaseAvailability.offersPurchases(
                bundleIdentifier: Self.internalBundle, account: state, offers: []))
        }
    }

    /// Once the server sells to INTERNAL and StoreKit loads its products, the
    /// offer comes back with no app change; until StoreKit has products it stays hidden.
    @Test func internalOffersOnceServerAndStoreKitSell() {
        #expect(BillingPurchaseAvailability.offersPurchases(
            bundleIdentifier: Self.internalBundle, account: Self.eligible, offers: [Self.offer]))
        #expect(!BillingPurchaseAvailability.offersPurchases(
            bundleIdentifier: Self.internalBundle, account: Self.eligible, offers: []))
    }
}

@MainActor
@Suite struct BillingModelOffersPurchasesTests {
    func model(account: BillingAccount, bundle: String?) async -> BillingModel {
        let log = EffectLog()
        let store = FakeStoreKitClient(log: log)
        await store.configure(products: [BillingFixtures.product(.pro, price: "$74.99")])
        return BillingModel(
            api: FakeBillingAPI(log: log, account: account),
            store: store,
            analytics: nil,
            bundleIdentifier: bundle
        )
    }

    @Test func internalBundleIsReadOnlyWhenServerSellsNothing() async {
        let model = await model(
            account: BillingFixtures.account(eligible: false, reason: .purchasesUnavailable),
            bundle: "dev.cmux.app.internal"
        )
        #expect(!model.offersPurchases)
        await model.refresh()
        #expect(!model.offersPurchases)
    }

    @Test func appStoreBundleKeepsTodaysScreenWhenServerSellsNothing() async {
        let model = await model(
            account: BillingFixtures.account(eligible: false, reason: .purchasesUnavailable),
            bundle: "com.cmux.app"
        )
        await model.refresh()
        #expect(model.offersPurchases)
    }

    @Test func internalBundleOffersOnceProductsLoad() async {
        let model = await model(account: BillingFixtures.account(products: [.pro]), bundle: "dev.cmux.app.internal")
        await model.refresh()
        #expect(model.offers.map(\.planID) == [.pro])
        #expect(model.offersPurchases)
    }
}
