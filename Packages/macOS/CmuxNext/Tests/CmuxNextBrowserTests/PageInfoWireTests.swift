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
/// closed or the tab navigated must not act on the new site.
struct PageInfoPageCommandGateTests {
    private let shown = URL(string: "https://a.example/page")!

    @Test func aCommandForTheShownSiteIsAccepted() {
        #expect(PageInfoController.acceptsPageCommand(isOpen: true, openedURL: shown, current: shown))
    }

    @Test func aCommandQueuedBeforeANavigationIsDropped() {
        #expect(!PageInfoController.acceptsPageCommand(isOpen: true, openedURL: shown, current: URL(string: "https://b.example/")))
    }

    @Test func aCommandAfterTheBubbleClosedIsDropped() {
        #expect(!PageInfoController.acceptsPageCommand(isOpen: false, openedURL: shown, current: shown))
        #expect(!PageInfoController.acceptsPageCommand(isOpen: true, openedURL: nil, current: nil))
    }
}
