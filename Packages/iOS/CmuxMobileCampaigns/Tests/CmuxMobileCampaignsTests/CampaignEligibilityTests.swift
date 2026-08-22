import Foundation
import Testing
@testable import CmuxMobileCampaigns

@Suite("Campaign eligibility")
struct CampaignEligibilityTests {
    private let august = Date(timeIntervalSince1970: 1_787_000_000)

    private func context(
        version: String = "1.0.5",
        rolloutKey: String = "install-a"
    ) -> CampaignEligibilityContext {
        CampaignEligibilityContext(
            appVersion: CampaignAppVersion(parsing: version),
            rolloutKey: rolloutKey,
            now: august
        )
    }

    private func campaign(
        id: String = "c",
        platforms: [String] = ["ios"],
        minAppVersion: String? = nil,
        maxAppVersion: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        rolloutPercent: Double = 100,
        reshowPolicy: Campaign.ReshowPolicy = .untilDismissed
    ) -> Campaign {
        Campaign(
            id: id,
            template: .sheet,
            platforms: platforms,
            minAppVersion: minAppVersion.flatMap(CampaignAppVersion.init(parsing:)),
            maxAppVersion: maxAppVersion.flatMap(CampaignAppVersion.init(parsing:)),
            startsAt: startsAt,
            endsAt: endsAt,
            rolloutPercent: rolloutPercent,
            reshowPolicy: reshowPolicy,
            title: CampaignText(en: "T"),
            body: CampaignText(en: "B")
        )
    }

    @Test func matchesPlatform() {
        #expect(CampaignEligibility.isTargeted(campaign(), context: context()))
        #expect(!CampaignEligibility.isTargeted(campaign(platforms: ["macos"]), context: context()))
        // Unknown platforms are ignored, not fatal.
        #expect(CampaignEligibility.isTargeted(
            campaign(platforms: ["visionos", "ios"]),
            context: context()
        ))
    }

    @Test func enforcesInclusiveVersionBounds() {
        let bounded = campaign(minAppVersion: "1.0.5", maxAppVersion: "1.1")
        #expect(CampaignEligibility.isTargeted(bounded, context: context(version: "1.0.5")))
        #expect(CampaignEligibility.isTargeted(bounded, context: context(version: "1.1")))
        #expect(CampaignEligibility.isTargeted(bounded, context: context(version: "1.1.0")))
        #expect(!CampaignEligibility.isTargeted(bounded, context: context(version: "1.0.4")))
        #expect(!CampaignEligibility.isTargeted(bounded, context: context(version: "1.1.1")))
    }

    @Test func enforcesDateWindow() {
        let past = august.addingTimeInterval(-3600)
        let future = august.addingTimeInterval(3600)
        #expect(CampaignEligibility.isTargeted(
            campaign(startsAt: past, endsAt: future),
            context: context()
        ))
        #expect(!CampaignEligibility.isTargeted(campaign(startsAt: future), context: context()))
        #expect(!CampaignEligibility.isTargeted(campaign(endsAt: past), context: context()))
        // endsAt is exclusive: an expired instant no longer matches.
        #expect(!CampaignEligibility.isTargeted(campaign(endsAt: august), context: context()))
    }

    @Test func rolloutIsDeterministicPerInstallAndCampaign() {
        let bucketA = CampaignEligibility.rolloutBucket(campaignID: "c1", rolloutKey: "install-a")
        #expect(bucketA == CampaignEligibility.rolloutBucket(campaignID: "c1", rolloutKey: "install-a"))
        #expect(bucketA >= 0 && bucketA < 100)
        // Different campaigns slice the population independently.
        let otherCampaign = CampaignEligibility.rolloutBucket(campaignID: "c2", rolloutKey: "install-a")
        let otherInstall = CampaignEligibility.rolloutBucket(campaignID: "c1", rolloutKey: "install-b")
        #expect(bucketA != otherCampaign || bucketA != otherInstall)
    }

    @Test func rolloutBoundsAreRespected() {
        #expect(!CampaignEligibility.isTargeted(campaign(rolloutPercent: 0), context: context()))
        #expect(CampaignEligibility.isTargeted(campaign(rolloutPercent: 100), context: context()))
    }

    @Test func reshowPolicies() {
        let version = CampaignAppVersion(parsing: "1.0.5")
        let fresh = CampaignPresentationState()
        let presentedNow = CampaignPresentationState(presentedVersions: ["1.0.5"])
        let presentedBefore = CampaignPresentationState(presentedVersions: ["1.0.4"])
        let dismissed = CampaignPresentationState(presentedVersions: ["1.0.5"], isDismissed: true)

        let once = campaign(reshowPolicy: .once)
        #expect(CampaignEligibility.passesReshowPolicy(once, state: fresh, appVersion: version))
        #expect(!CampaignEligibility.passesReshowPolicy(once, state: presentedNow, appVersion: version))
        #expect(!CampaignEligibility.passesReshowPolicy(once, state: presentedBefore, appVersion: version))

        let perVersion = campaign(reshowPolicy: .oncePerVersion)
        #expect(CampaignEligibility.passesReshowPolicy(perVersion, state: fresh, appVersion: version))
        #expect(!CampaignEligibility.passesReshowPolicy(perVersion, state: presentedNow, appVersion: version))
        #expect(CampaignEligibility.passesReshowPolicy(perVersion, state: presentedBefore, appVersion: version))

        let untilDismissed = campaign(reshowPolicy: .untilDismissed)
        #expect(CampaignEligibility.passesReshowPolicy(untilDismissed, state: presentedNow, appVersion: version))

        // Explicit dismissal beats every policy.
        for policy in [Campaign.ReshowPolicy.once, .oncePerVersion, .untilDismissed] {
            #expect(!CampaignEligibility.passesReshowPolicy(
                campaign(reshowPolicy: policy),
                state: dismissed,
                appVersion: version
            ))
        }
    }

    @Test func sortsByPriorityThenID() {
        let sorted = CampaignEligibility.sortedByPriority([
            Campaign(id: "b", template: .sheet, priority: 1, reshowPolicy: .once,
                     title: CampaignText(en: "T"), body: CampaignText(en: "B")),
            Campaign(id: "a", template: .sheet, priority: 1, reshowPolicy: .once,
                     title: CampaignText(en: "T"), body: CampaignText(en: "B")),
            Campaign(id: "c", template: .sheet, priority: 9, reshowPolicy: .once,
                     title: CampaignText(en: "T"), body: CampaignText(en: "B")),
        ])
        #expect(sorted.map(\.id) == ["c", "a", "b"])
    }
}

@Suite("Campaign state store")
struct CampaignStateStoreTests {
    @Test func recordsPresentationsAndDismissals() throws {
        let suiteName = "CmuxMobileCampaignsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CampaignStateStore(defaults: defaults)

        #expect(store.state(for: "c1") == CampaignPresentationState())

        store.recordPresented(campaignID: "c1", appVersion: "1.0.5")
        store.recordPresented(campaignID: "c1", appVersion: "1.0.5")
        store.recordPresented(campaignID: "c1", appVersion: "1.0.6")
        #expect(store.state(for: "c1").presentedVersions == ["1.0.5", "1.0.6"])
        #expect(!store.state(for: "c1").isDismissed)

        store.recordDismissed(campaignID: "c1")
        #expect(store.state(for: "c1").isDismissed)
        // Other campaigns are unaffected.
        #expect(store.state(for: "c2") == CampaignPresentationState())
    }
}
