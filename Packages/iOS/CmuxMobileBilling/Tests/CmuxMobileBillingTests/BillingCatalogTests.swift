import Foundation
import Testing

@testable import CmuxMobileBilling

struct BillingCatalogTests {
    @Test func ineligibleAccountsUseTheNextCatalog() {
        let account = BillingAccount(
            appAccountToken: UUID(),
            eligible: false,
            reason: .purchasesUnavailable,
            currentPlan: BillingCurrentPlan(planID: .nextPro, source: .none),
            products: []
        )

        #expect(account.catalogPlanIDs == [.nextPlus, .nextPro, .nextMax])
        let allNext = account.catalogPlanIDs.allSatisfy { plan in plan.isNext }
        #expect(allNext)
    }

    @Test func classicAccountRetainsClassicCatalog() {
        let account = BillingAccount(
            appAccountToken: UUID(),
            eligible: false,
            reason: .purchasesUnavailable,
            currentPlan: BillingCurrentPlan(planID: .go, source: .none),
            products: []
        )

        #expect(account.catalogPlanIDs == [.go, .pro, .max])
        #expect(!BillingPlanID.pro.isNext)
        #expect(BillingPlanID.nextPlus < .nextPro && BillingPlanID.nextPro < .nextMax)
    }

    @Test func explicitNextFamilyHandlesEmptyIneligibleResponse() {
        let account = BillingAccount(
            appAccountToken: UUID(),
            eligible: false,
            reason: .purchasesUnavailable,
            currentPlan: BillingCurrentPlan(planID: .free, source: .none),
            products: [],
            catalogFamily: .next
        )

        #expect(account.catalogPlanIDs == [.nextPlus, .nextPro, .nextMax])
    }

    @Test func explicitFamilySurvivesCodableRoundTrip() throws {
        let original = BillingAccount(
            appAccountToken: UUID(),
            eligible: false,
            reason: .purchasesUnavailable,
            currentPlan: BillingCurrentPlan(planID: .free, source: .none),
            products: [],
            catalogFamily: .next
        )
        let decoded = try JSONDecoder().decode(BillingAccount.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.catalogPlanIDs == [.nextPlus, .nextPro, .nextMax])
    }

    @Test func nextProductsSelectNextFamilyForFreeAccount() {
        let account = BillingAccount(
            appAccountToken: UUID(),
            eligible: true,
            reason: nil,
            currentPlan: BillingCurrentPlan(planID: .free, source: .none),
            products: [BillingProductReference(productID: "com.cmux.app.next_plus.monthly", planID: .nextPlus)]
        )
        #expect(account.catalogPlanIDs == [.nextPlus, .nextPro, .nextMax])
    }
}
