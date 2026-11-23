import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Page Info's "Delete site data" on a Chromium tab read the cookie jar with `try?`: an unreadable jar
/// deleted no cookie and answered as if it had, and the counts read after it looked like the data were
/// gone. The delete now throws what it could not do, still clearing storage, and the bubble shows the
/// failure with its reason in the counts' place.
@MainActor
struct PageInfoDeleteSiteDataFailureTests {
    private struct Unreadable: LocalizedError {
        var errorDescription: String? { "cookie visit timed out" }
    }

    @MainActor
    private final class Calls {
        var deleted: [String] = []
        var cleared: [String] = []
    }

    private static func deleteSiteData(_ calls: Calls, read: () async throws -> [CEFCookie],
                                       failDelete: Bool = false) async -> PageInfoSiteDataDeleteError? {
        do throws(PageInfoSiteDataDeleteError) {
            try await CEFTab.deleteSiteData(
                domains: ["example.com"], readCookies: read,
                deleteCookie: { cookie in
                    if failDelete { throw Unreadable() }
                    calls.deleted.append(cookie.name)
                },
                clearStorage: { calls.cleared.append($0) })
            return nil
        } catch {
            return error
        }
    }

    @Test func aFailingCookieReadIsAnErrorNotSuccess() async {
        let calls = Calls()
        let failure = await Self.deleteSiteData(calls, read: { throw Unreadable() })
        #expect(failure == .cookiesUnreadable(reason: "cookie visit timed out"))
        // Storage is still cleared: the person keeps what could be done.
        #expect(calls.cleared == ["https://example.com", "http://example.com"])
        // Out of the macro: #expect's expansion of `failure?.reason ?? ""` did not compile (fleet compile b43757874a484e13de29d41e).
        let reason = failure?.reason ?? ""
        #expect(PageInfoStrings.deleteSiteDataFailed(reason).contains("cookie visit timed out"))
    }

    @Test func cookiesThatStayAreCountedWithTheReason() async {
        let calls = Calls()
        let cookies = [CEFCookie(name: "a", domain: ".example.com", path: "/"), CEFCookie(name: "b", domain: "www.example.com", path: "/"),
                       CEFCookie(name: "c", domain: "other.net", path: "/")]
        let failure = await Self.deleteSiteData(calls, read: { cookies }, failDelete: true)
        #expect(failure == .cookiesNotDeleted(count: 2, reason: "cookie visit timed out"))
    }

    @Test func aReadableJarDeletesTheSitesCookiesAndSucceeds() async {
        let calls = Calls()
        let cookies = [CEFCookie(name: "a", domain: ".example.com", path: "/"), CEFCookie(name: "c", domain: "other.net", path: "/")]
        let failure = await Self.deleteSiteData(calls, read: { cookies })
        #expect(failure == nil)
        #expect(calls.deleted == ["a"])
    }

    @Test func theCookiesPageShowsTheFailureInTheCountsPlace() throws {
        let model = PageInfoModel()
        model.site = PageInfoSite(url: URL(string: "https://example.com/a"), kind: .web(.secure))
        model.page = .cookies
        model.siteData = SiteDataSummary(entries: [SiteDataEntry(domain: "example.com", cookieCount: 3, isThirdParty: false)])
        model.siteDataDeleteFailure = .cookiesUnreadable(reason: "cookie visit timed out")
        let page = PageInfoPages(model: model, send: { _ in }).build()
        let manage = try #require(Self.find("pageInfo.manageSiteData", in: page))
        #expect(manage.subtitleLabel.stringValue == PageInfoStrings.deleteSiteDataFailed("cookies could not be read (cookie visit timed out)"))
    }

    @Test func theMockEngineCarriesTheFailureThroughTheProtocol() async {
        let tab = MockBrowserEngine().makeMockTab(.init(initialURL: URL(string: "https://example.com")))
        tab.pageInfoFake.cookieDomains = ["example.com"]
        tab.pageInfoFake.deleteFailure = .cookiesUnreadable(reason: "jar")
        let provider: any PageInfoProviding = tab
        await #expect(throws: PageInfoSiteDataDeleteError.cookiesUnreadable(reason: "jar")) {
            try await provider.pageInfoDeleteSiteData(domains: ["example.com"])
        }
        #expect(tab.pageInfoFake.cookieDomains == ["example.com"])
    }

    private static func find(_ id: String, in view: NSView) -> PageInfoRowView? {
        if let found = view as? PageInfoRowView, found.identifier?.rawValue == id { return found }
        for child in view.subviews {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }
}
