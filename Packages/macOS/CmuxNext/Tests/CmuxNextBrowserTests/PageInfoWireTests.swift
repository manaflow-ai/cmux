import Foundation
import Testing
@testable import CmuxNextBrowser

/// The Page Info bubble's wire to its React page (webviews/src/pages/page-info).
@MainActor
struct PageInfoWireTests {
    @Test func everyCommandThePageSendsParses() {
        #expect(PageInfoCommand(wire: ["type": "show", "page": ["type": "security"]]) == .show(.security))
        #expect(PageInfoCommand(wire: ["type": "show", "page": ["type": "permission", "kind": "camera"]]) == .show(.permission(.camera)))
        #expect(PageInfoCommand(wire: ["type": "setPermission", "kind": "camera", "setting": "block"]) == .setPermission(.camera, .block))
        #expect(PageInfoCommand(wire: ["type": "deleteSiteData", "domain": "a.com"]) == .deleteSiteData(domain: "a.com"))
        #expect(PageInfoCommand(wire: ["type": "deleteSiteData"]) == .deleteSiteData(domain: nil))
        for type in ["showCertificate", "resetPermissions", "siteSettings", "manageSiteData", "aboutThisPage", "reenableCertificateWarnings", "reload", "close"] {
            #expect(PageInfoCommand(wire: ["type": type]) != nil)
        }
    }

    @Test func aCommandOutsideTheBubblesChoicesIsRefused() {
        #expect(PageInfoCommand(wire: ["type": "setPermission", "kind": "camera", "setting": "nonsense"]) == nil)
        #expect(PageInfoCommand(wire: ["type": "setPermission", "kind": "nonsense", "setting": "allow"]) == nil)
        #expect(PageInfoCommand(wire: ["type": "show", "page": ["type": "permission"]]) == nil)
        #expect(PageInfoCommand(wire: ["type": "runScript"]) == nil)
        // A malformed domain is no "delete every site's data".
        #expect(PageInfoCommand(wire: ["type": "deleteSiteData", "domain": 42]) == nil)
        #expect(PageInfoCommand(wire: ["type": "deleteSiteData", "domain": ["a.com"]]) == nil)
    }

    @Test func theStateCarriesThePageSiteAndRows() throws {
        let model = PageInfoModel()
        model.site = PageInfoSite(url: URL(string: "https://example.com/a"), kind: .web(.secure))
        model.page = .permission(.camera)
        model.permissions = [SitePermissionState(kind: .camera, setting: .block, isDefault: false, isInUse: false)]
        let state = model.wireState
        let data = try JSONSerialization.data(withJSONObject: state)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((decoded["page"] as? [String: String]) == ["type": "permission", "kind": "camera"])
        let site = try #require(decoded["site"] as? [String: Any])
        #expect(site["kind"] as? String == "web")
        #expect(site["connection"] as? String == "secure")
        #expect(site["displayName"] as? String == "example.com")
        let rows = try #require(decoded["permissions"] as? [[String: Any]])
        #expect(rows.first?["setting"] as? String == "block")
        #expect(decoded["siteData"] is NSNull)
        #expect((decoded["certificate"] as? [String: Any])?["valid"] as? Bool == true)
    }
}

/// A command the bubble's page queued is for the site it showed: one that arrives after the bubble
/// closed, after the tab navigated, or after a reopen (on another site or the same) must not act.
struct PageInfoPageCommandGateTests {
    private let shown = URL(string: "https://a.example/page")!

    @Test func aCommandFromThisOpeningForTheShownSiteIsAccepted() {
        #expect(PageInfoController.acceptsPageCommand(isOpen: true, opening: 2, from: 2, openedURL: shown, current: shown))
    }

    @Test func aCommandQueuedBeforeANavigationIsDropped() {
        #expect(!PageInfoController.acceptsPageCommand(isOpen: true, opening: 2, from: 2, openedURL: shown,
                                                       current: URL(string: "https://b.example/")))
    }

    @Test func aCommandFromAnEarlierOpeningIsDropped() {
        // Site A's click arrives after the bubble closed, the tab went to B and the bubble reopened.
        let other = URL(string: "https://b.example/")!
        #expect(!PageInfoController.acceptsPageCommand(isOpen: true, opening: 3, from: 2, openedURL: other, current: other))
        #expect(!PageInfoController.acceptsPageCommand(isOpen: true, opening: 3, from: nil, openedURL: other, current: other))
    }

    @Test func aCommandAfterTheBubbleClosedIsDropped() {
        #expect(!PageInfoController.acceptsPageCommand(isOpen: false, opening: 2, from: 2, openedURL: shown, current: shown))
        #expect(!PageInfoController.acceptsPageCommand(isOpen: true, opening: 2, from: 2, openedURL: nil, current: nil))
    }
}
