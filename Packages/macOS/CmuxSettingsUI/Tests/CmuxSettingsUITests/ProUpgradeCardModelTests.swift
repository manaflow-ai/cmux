import CMUXMobileCore
import Testing
@testable import CmuxSettingsUI

/// The Settings plan row offers the next tier and never asks a Max
/// subscriber to upgrade to Pro.
@Suite struct ProUpgradeCardModelTests {
    @Test func freeAndGoAreOfferedPro() {
        for tier in [CmuxPlanTier.free, .go] {
            let model = ProUpgradeCardModel(tier: tier, isProActive: tier == .go, canManageBilling: false, isSignedIn: true)
            #expect(model.actions == [.upgradeToPro], "\(tier)")
        }
    }

    @Test func managedGoKeepsBillingBesideTheProOffer() {
        let model = ProUpgradeCardModel(tier: .go, isProActive: true, canManageBilling: true, isSignedIn: true)
        #expect(model.actions == [.upgradeToPro, .manageBilling])
    }

    @Test func proIsOfferedMaxAndBilling() {
        let model = ProUpgradeCardModel(tier: .pro, isProActive: true, canManageBilling: true, isSignedIn: true)
        #expect(model.actions == [.upgradeToMax, .manageBilling])
        #expect(!model.actions.contains(.upgradeToPro))
    }

    @Test func maxIsOfferedNoUpgrade() {
        let managed = ProUpgradeCardModel(tier: .max, isProActive: true, canManageBilling: true, isSignedIn: true)
        #expect(managed.actions == [.manageBilling])
        #expect(managed.title == String(localized: "settings.account.max.title", defaultValue: "cmux Max"))

        let external = ProUpgradeCardModel(tier: .max, isProActive: true, canManageBilling: false, isSignedIn: true)
        #expect(external.actions.isEmpty)
    }

    @Test func unknownPlanForASignedInAccountOffersNothing() {
        let model = ProUpgradeCardModel(tier: nil, isProActive: false, canManageBilling: false, isSignedIn: true)
        #expect(model.actions.isEmpty)
    }

    @Test func signedOutIsOfferedPro() {
        let model = ProUpgradeCardModel(tier: nil, isProActive: false, canManageBilling: false, isSignedIn: false)
        #expect(model.actions == [.upgradeToPro])
    }
}
