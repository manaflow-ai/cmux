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

    @Test func classicPlansRemainVisibleOnlyWhenCurrentOrOnSale() {
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
}
