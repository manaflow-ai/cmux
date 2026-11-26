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

    @Test func appStoreProSaysWhereBillingIsManaged() {
        let model = ProUpgradeCardModel(
            tier: .pro, isProActive: true, canManageBilling: false, isSignedIn: true, billingSource: .appStore
        )
        #expect(model.subtitle == "Your Pro subscription is active. Manage it through your subscription provider.")
        #expect(!model.subtitle.contains("previous billing system"))
        #expect(model.actions == [.upgradeToMax])
    }

    @Test func grantedProHasNoBillingLine() {
        let model = ProUpgradeCardModel(
            tier: .pro, isProActive: true, canManageBilling: false, isSignedIn: true, billingSource: .granted
        )
        #expect(model.subtitle == "Your Pro plan is active.")
        #expect(model.actions == [.upgradeToMax])
    }

    @Test func stripeProKeepsTheStripeBillingLine() {
        let model = ProUpgradeCardModel(
            tier: .pro, isProActive: true, canManageBilling: true, isSignedIn: true, billingSource: .stripe
        )
        #expect(model.actions == [.upgradeToMax, .manageBilling])
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
