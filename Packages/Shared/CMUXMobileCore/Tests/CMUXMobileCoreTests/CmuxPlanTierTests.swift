import Testing
@testable import CMUXMobileCore

@Suite struct CmuxPlanTierTests {
    @Test func everyHigherTierIncludesTheFeaturesBelowIt() {
        #expect(CmuxPlanTier.free.includesCloud == false)
        #expect(CmuxPlanTier.free.includesPro == false)
        #expect(CmuxPlanTier.free.includesMax == false)

        #expect(CmuxPlanTier.go.includesCloud)
        #expect(CmuxPlanTier.go.includesPro == false)
        #expect(CmuxPlanTier.go.includesMax == false)

        #expect(CmuxPlanTier.pro.includesCloud)
        #expect(CmuxPlanTier.pro.includesPro)
        #expect(CmuxPlanTier.pro.includesMax == false)

        #expect(CmuxPlanTier.max.includesCloud)
        #expect(CmuxPlanTier.max.includesPro)
        #expect(CmuxPlanTier.max.includesMax)
    }

    @Test func planIDsMapToTiers() {
        #expect(CmuxPlanTier(planID: "free") == .free)
        #expect(CmuxPlanTier(planID: "go") == .go)
        #expect(CmuxPlanTier(planID: "pro") == .pro)
        #expect(CmuxPlanTier(planID: " MAX ") == .max)
        // Team and legacy Founder grants grant the Pro feature set.
        #expect(CmuxPlanTier(planID: "team") == .pro)
        #expect(CmuxPlanTier(planID: "founders") == .pro)
        #expect(CmuxPlanTier(planID: "enterprise") == nil)
        #expect(CmuxPlanTier(planID: "") == nil)
        #expect(CmuxPlanTier(planID: nil) == nil)
    }

    @Test func nextUpgradeOffersTheTierAbove() {
        #expect(CmuxPlanTier.free.nextUpgrade == .pro)
        #expect(CmuxPlanTier.go.nextUpgrade == .pro)
        #expect(CmuxPlanTier.pro.nextUpgrade == .max)
        #expect(CmuxPlanTier.max.nextUpgrade == nil)
    }

    @Test func maxSubscriberResolvesToMaxFromTheExactPlan() {
        // `/api/billing/plan` reports a Max subscriber as planId "pro" for
        // older clients and carries "max" in subscriptionPlanId.
        let tier = CmuxPlanTier.resolved(
            subscriptionPlanID: "max",
            planID: "pro",
            teamPlanID: "free",
            isPro: true
        )
        #expect(tier == .max)
        #expect(tier.nextUpgrade == nil)
    }

    @Test func goSubscriberIsNotPromotedToProByTheLegacyFlag() {
        // The service sets isPro for every paid personal plan, Go included.
        let tier = CmuxPlanTier.resolved(
            subscriptionPlanID: "go",
            planID: "pro",
            teamPlanID: "free",
            isPro: true
        )
        #expect(tier == .go)
        #expect(tier.nextUpgrade == .pro)
    }

    @Test func paidTeamRaisesAFreePersonalPlan() {
        let tier = CmuxPlanTier.resolved(
            subscriptionPlanID: "free",
            planID: "free",
            teamPlanID: "team",
            isPro: false
        )
        #expect(tier == .pro)
    }

    @Test func personalMaxIsKeptOnAFreeOrTeamWorkspace() {
        #expect(CmuxPlanTier.resolved(subscriptionPlanID: "max", planID: "pro", teamPlanID: "team", isPro: true) == .max)
    }

    @Test func olderServersFallBackToTheLegacyPlanFamily() {
        #expect(CmuxPlanTier.resolved(subscriptionPlanID: nil, planID: "pro", teamPlanID: nil, isPro: true) == .pro)
        #expect(CmuxPlanTier.resolved(subscriptionPlanID: nil, planID: nil, teamPlanID: nil, isPro: true) == .pro)
        #expect(CmuxPlanTier.resolved(subscriptionPlanID: nil, planID: nil, teamPlanID: nil, isPro: false) == .free)
    }

    @Test func upgradeOfferFollowsTheKnownTier() {
        // Signed out: the entry plan is the useful offer.
        #expect(CmuxPlanTier.upgradeOffer(isSignedIn: false, knownTier: nil) == .pro)
        // Signed in but the plan is still loading or its fetch failed: never
        // read that as Free, so offer nothing rather than the wrong plan.
        #expect(CmuxPlanTier.upgradeOffer(isSignedIn: true, knownTier: nil) == nil)
        #expect(CmuxPlanTier.upgradeOffer(isSignedIn: true, knownTier: .free) == .pro)
        #expect(CmuxPlanTier.upgradeOffer(isSignedIn: true, knownTier: .go) == .pro)
        #expect(CmuxPlanTier.upgradeOffer(isSignedIn: true, knownTier: .pro) == .max)
        #expect(CmuxPlanTier.upgradeOffer(isSignedIn: true, knownTier: .max) == nil)
    }
}
