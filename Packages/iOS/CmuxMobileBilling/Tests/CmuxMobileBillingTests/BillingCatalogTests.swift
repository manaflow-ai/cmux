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
        #expect(account.catalogPlanIDs.allSatisfy(\.isNext))
    }

    @Test func classicPlansRemainVisibleOnlyWhenCurrentOrOnSale() {
        let account = BillingAccount(
            appAccountToken: UUID(),
            eligible: false,
            reason: .purchasesUnavailable,
            currentPlan: BillingCurrentPlan(planID: .go, source: .none),
            products: []
        )

        #expect(account.catalogPlanIDs == [.go, .nextPlus, .nextPro, .nextMax])
        #expect(!BillingPlanID.pro.isNext)
        #expect(BillingPlanID.nextPlus < .nextPro && BillingPlanID.nextPro < .nextMax)
    }
}
