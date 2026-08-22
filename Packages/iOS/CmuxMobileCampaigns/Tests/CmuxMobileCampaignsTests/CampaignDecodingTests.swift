import Foundation
import Testing
@testable import CmuxMobileCampaigns

@Suite("Campaign catalog decoding")
struct CampaignDecodingTests {
    private func decode(_ json: String) throws -> CampaignCatalog {
        try CampaignCatalog.decode(from: Data(json.utf8))
    }

    private let fullCampaign = """
    {
      "id": "sample-launch",
      "template": "sheet",
      "platforms": ["ios"],
      "minAppVersion": "1.0.5",
      "maxAppVersion": "2.0",
      "startsAt": "2026-08-01T00:00:00.000Z",
      "endsAt": "2026-12-01T00:00:00Z",
      "rolloutPercent": 50,
      "priority": 10,
      "reshowPolicy": "once",
      "showInWhatsNew": true,
      "title": {"en": "New in cmux", "ja": "cmux の新機能"},
      "body": {"en": "Try it.", "ja": "お試しください。"},
      "image": {"light": "/campaigns/sample.png", "aspectRatio": 2},
      "accentColor": "#5B8DEF",
      "buttons": [
        {"label": {"en": "Learn more", "ja": "詳細"}, "action": {"type": "openURL", "url": "https://cmux.com/changelog"}},
        {"label": {"en": "Not now", "ja": "あとで"}, "action": {"type": "dismiss"}, "role": "secondary"}
      ]
    }
    """

    @Test func decodesFullyPopulatedCampaign() throws {
        let catalog = try decode("""
        {"schemaVersion": 1, "updatedAt": "2026-08-21T00:00:00.000Z", "campaigns": [\(fullCampaign)]}
        """)
        let campaign = try #require(catalog.campaigns.first)
        #expect(campaign.id == "sample-launch")
        #expect(campaign.template == .sheet)
        #expect(campaign.minAppVersion == CampaignAppVersion(parsing: "1.0.5"))
        #expect(campaign.rolloutPercent == 50)
        #expect(campaign.priority == 10)
        #expect(campaign.showInWhatsNew)
        #expect(campaign.startsAt != nil)
        #expect(campaign.endsAt != nil)
        #expect(campaign.buttons.count == 2)
        #expect(campaign.buttons[0].action == .openURL(URL(string: "https://cmux.com/changelog")!))
        #expect(campaign.buttons[1].role == .secondary)
        #expect(campaign.title.resolved(languageCode: "ja") == "cmux の新機能")
        #expect(campaign.title.resolved(languageCode: "en") == "New in cmux")
    }

    @Test func appliesDefaultsForOmittedFields() throws {
        let catalog = try decode("""
        {"schemaVersion": 1, "campaigns": [{
          "id": "minimal", "template": "banner", "platforms": ["ios"],
          "reshowPolicy": "untilDismissed",
          "title": {"en": "Hi"}, "body": {"en": "There"}
        }]}
        """)
        let campaign = try #require(catalog.campaigns.first)
        #expect(campaign.rolloutPercent == 100)
        #expect(campaign.priority == 0)
        #expect(!campaign.showInWhatsNew)
        #expect(campaign.buttons.isEmpty)
        #expect(campaign.title.resolved(languageCode: "ja") == "Hi")
    }

    @Test func dropsUnknownTemplatesAndKeepsTheRest() throws {
        let catalog = try decode("""
        {"schemaVersion": 1, "campaigns": [
          {"id": "future", "template": "hologram", "platforms": ["ios"],
           "reshowPolicy": "once", "title": {"en": "X"}, "body": {"en": "Y"}},
          {"id": "kept", "template": "sheet", "platforms": ["ios"],
           "reshowPolicy": "once", "title": {"en": "X"}, "body": {"en": "Y"}}
        ]}
        """)
        #expect(catalog.campaigns.map(\.id) == ["kept"])
    }

    @Test func dropsCampaignsWithUnsupportedButtonActions() throws {
        let catalog = try decode("""
        {"schemaVersion": 1, "campaigns": [{
          "id": "future-action", "template": "sheet", "platforms": ["ios"],
          "reshowPolicy": "once", "title": {"en": "X"}, "body": {"en": "Y"},
          "buttons": [{"label": {"en": "Go"}, "action": {"type": "startCheckout"}}]
        }]}
        """)
        #expect(catalog.campaigns.isEmpty)
    }

    @Test func dropsCampaignsWithNonHTTPSButtonURLs() throws {
        let catalog = try decode("""
        {"schemaVersion": 1, "campaigns": [{
          "id": "insecure", "template": "sheet", "platforms": ["ios"],
          "reshowPolicy": "once", "title": {"en": "X"}, "body": {"en": "Y"},
          "buttons": [{"label": {"en": "Go"}, "action": {"type": "openURL", "url": "http://cmux.com"}}]
        }]}
        """)
        #expect(catalog.campaigns.isEmpty)
    }

    @Test func rendersNothingForNewerSchemaVersions() throws {
        let catalog = try decode("""
        {"schemaVersion": 2, "campaigns": [\(fullCampaign)]}
        """)
        #expect(catalog.campaigns.isEmpty)
    }

    @Test func dropsMalformedElementsWithoutFailingTheCatalog() throws {
        let catalog = try decode("""
        {"schemaVersion": 1, "campaigns": [
          "not-an-object",
          {"id": "missing-fields"},
          {"id": "kept", "template": "fullscreen", "platforms": ["ios"],
           "reshowPolicy": "oncePerVersion", "title": {"en": "X"}, "body": {"en": "Y"}}
        ]}
        """)
        #expect(catalog.campaigns.map(\.id) == ["kept"])
    }
}

@Suite("Campaign app version")
struct CampaignAppVersionTests {
    @Test func comparesPerComponentWithZeroPadding() throws {
        let v105 = try #require(CampaignAppVersion(parsing: "1.0.5"))
        let v10 = try #require(CampaignAppVersion(parsing: "1.0"))
        let v100 = try #require(CampaignAppVersion(parsing: "1.0.0"))
        let v1010 = try #require(CampaignAppVersion(parsing: "1.0.10"))
        let v109 = try #require(CampaignAppVersion(parsing: "1.0.9"))
        #expect(v10 == v100)
        #expect(v10 < v105)
        #expect(v109 < v1010)
        #expect(!(v1010 < v109))
    }

    @Test func rejectsNonNumericVersions() {
        #expect(CampaignAppVersion(parsing: "v1.2") == nil)
        #expect(CampaignAppVersion(parsing: "1.2-beta") == nil)
        #expect(CampaignAppVersion(parsing: "") == nil)
        #expect(CampaignAppVersion(parsing: "1..2") == nil)
    }
}
