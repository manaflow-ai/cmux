import Foundation
import Testing
@testable import CmuxMobileCampaigns

@MainActor
private final class EventRecorder: CampaignEventReporting {
    var events: [CampaignEvent] = []
    func campaignEvent(_ event: CampaignEvent) {
        events.append(event)
    }
}

@MainActor
@Suite("Mobile campaign center")
struct MobileCampaignCenterTests {
    private static let cachedCatalog = """
    {"schemaVersion": 1, "campaigns": [
      {"id": "modal-low", "template": "sheet", "platforms": ["ios"], "priority": 1,
       "reshowPolicy": "untilDismissed", "showInWhatsNew": true,
       "title": {"en": "Low"}, "body": {"en": "B"}},
      {"id": "modal-high", "template": "fullscreen", "platforms": ["ios"], "priority": 5,
       "reshowPolicy": "untilDismissed",
       "title": {"en": "High"}, "body": {"en": "B"}},
      {"id": "hint", "template": "banner", "platforms": ["ios"],
       "reshowPolicy": "untilDismissed",
       "title": {"en": "Banner"}, "body": {"en": "B"}}
    ]}
    """

    private func makeCenter(
        reporter: EventRecorder? = nil
    ) throws -> (MobileCampaignCenter, UserDefaults, String) {
        let suiteName = "CmuxMobileCampaignsTests.center.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(Data(Self.cachedCatalog.utf8), forKey: "dev.cmux.mobile.campaigns.cache")
        let center = MobileCampaignCenter(
            apiBaseURL: "https://cmux.invalid",
            appVersionString: "1.0.5",
            rolloutKey: "install-a",
            defaults: defaults,
            reporter: reporter
        )
        return (center, defaults, suiteName)
    }

    @Test func loadsCachedCatalogAndSelectsSurfacesByPriority() throws {
        let (center, defaults, suiteName) = try makeCenter()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(center.activeBanner?.id == "hint")
        #expect(center.pendingModal?.id == "modal-high")
        #expect(center.whatsNewCampaigns.map(\.id) == ["modal-low"])
    }

    @Test func presentsAtMostOneModalPerForeground() throws {
        let (center, defaults, suiteName) = try makeCenter()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try #require(center.takePendingModal())
        #expect(first.id == "modal-high")
        // The gate holds even though modal-low is still presentable.
        #expect(center.takePendingModal() == nil)

        center.didBecomeActive()
        let second = try #require(center.takePendingModal())
        #expect(second.id == "modal-high")
    }

    @Test func dismissalRemovesSurfacesAndPersistsAcrossInstances() throws {
        let reporter = EventRecorder()
        let (center, defaults, suiteName) = try makeCenter(reporter: reporter)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let modal = try #require(center.takePendingModal())
        center.recordPresented(modal)
        center.recordDismissed(modal, source: "close")
        center.didBecomeActive()
        #expect(center.takePendingModal()?.id == "modal-low")
        #expect(reporter.events.contains(.impression(campaignID: "modal-high", template: "fullscreen")))
        #expect(reporter.events.contains(.dismissed(campaignID: "modal-high", source: "close")))

        // A fresh center over the same defaults must not resurface it.
        let rebuilt = MobileCampaignCenter(
            apiBaseURL: "https://cmux.invalid",
            appVersionString: "1.0.5",
            rolloutKey: "install-a",
            defaults: defaults
        )
        #expect(rebuilt.pendingModal?.id == "modal-low")
    }

    @Test func resolvesRelativeAndAbsoluteImageURLs() throws {
        let (center, defaults, suiteName) = try makeCenter()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            center.imageURL(for: "/campaigns/a.png")?.absoluteString
                == "https://cmux.invalid/campaigns/a.png"
        )
        #expect(
            center.imageURL(for: "https://cdn.cmux.com/a.png")?.absoluteString
                == "https://cdn.cmux.com/a.png"
        )
    }
}
