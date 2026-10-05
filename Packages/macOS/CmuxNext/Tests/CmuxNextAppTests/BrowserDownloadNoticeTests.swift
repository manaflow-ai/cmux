import Foundation
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Testing

/// No silent drops: a download a site's automatic-downloads setting
/// blocked is listed with a notice that names the file and offers that
/// site's Site settings, where the choice changes.
@MainActor
@Suite struct BrowserDownloadNoticeTests {
    private func ended(_ status: BrowserDownload.Status, site: String? = nil) -> BrowserDownload {
        let item = BrowserDownload(sourceURL: URL(string: "https://files.example/a.zip"), filename: "a.zip")
        item.blockedSite = site
        item.complete(status)
        return item
    }

    @Test func aBlockedDownloadOffersItsSiteSettings() throws {
        let list = BrowserDownloadList()
        var notices: [BrowserDownloadNotice] = []
        let item = BrowserDownload(sourceURL: URL(string: "https://files.example/a.zip"), filename: "a.zip")
        list.add(item, tab: "tab") { notices.append($0) }
        item.blockedSite = "https://files.example"
        item.complete(.blocked("Blocked"))
        #expect(list.items.map(\.id) == [item.id])
        #expect(notices == [BrowserDownloadNotice(text: BrowserHitStrings.downloadBlocked("a.zip"), siteSettingsOrigin: "https://files.example")])
    }

    @Test func otherEndsOfferNoSiteSettings() {
        #expect(BrowserDownloadList.notice(for: ended(.finished))?.siteSettingsOrigin == nil)
        #expect(BrowserDownloadList.notice(for: ended(.failed("x")))?.siteSettingsOrigin == nil)
        // A page without an origin (data:, about:blank) has no site to set.
        #expect(BrowserDownloadList.notice(for: ended(.blocked("Blocked")))?.siteSettingsOrigin == nil)
        #expect(BrowserDownloadList.notice(for: ended(.cancelled)) == nil)
    }
}
