#if os(iOS)
import Foundation
import Testing
import WebKit
@testable import CmuxMobileWorkspaces

/// The phone side of Open on iPhone's sign-in hand-off (`site-data`, RFD 0089):
/// the Mac's frame goes into the tab's web data store before the page loads.
@MainActor
struct SiteDataHandOffTests {
    static let frame = Data("""
    {"v":1,"site":"example.com","url":"https://app.example.com/","handed_at_ms":1800000000000,
     "cookies":[
       {"name":"sid","value":"abc","domain":".example.com","path":"/","expires_ms":1800086400000,
        "secure":true,"http_only":true,"same_site":"lax"},
       {"name":"theme","value":"dark","domain":"app.example.com","path":"/","secure":false,"http_only":false}
     ],
     "local_storage":[{"origin":"https://app.example.com","items":[["token","t1"]]}]}
    """.utf8)

    @Test func decodesTheMacsFrame() throws {
        let handOff = try #require(SiteDataHandOff.decode(Self.frame))
        #expect(handOff.site == "example.com")
        let cookies = handOff.httpCookies
        #expect(cookies.map(\.name) == ["sid", "theme"])
        #expect(cookies[0].isSecure && cookies[0].isHTTPOnly)
        #expect(cookies[0].expiresDate == Date(timeIntervalSince1970: 1_800_086_400))
        #expect(cookies[1].isSessionOnly, "a session cookie stays one")
        let script = try #require(handOff.storageScript)
        #expect(script.contains("https://app.example.com") && script.contains("t1"))
    }

    @Test func refusesAnUnknownVersion() {
        #expect(SiteDataHandOff.decode(Data(#"{"v":2,"site":"a.com","cookies":[],"local_storage":[]}"#.utf8)) == nil)
        #expect(SiteDataHandOff.decode(Data("not json".utf8)) == nil)
    }

    @Test func openOnIPhoneSetsTheCookiesBeforeTheLoad() async throws {
        let tabs = NativeBrowserTabs(defaults: UserDefaults(suiteName: "site-data-\(UUID())")!)
        var asked: [String] = []
        tabs.macHandsSiteData = { $0 == "mac" }
        tabs.siteData = { macID, tab, url in
            asked.append("\(macID ?? "-") \(tab) \(url)")
            return Self.frame
        }
        let handed = AsyncStream<Bool>.makeStream()
        let model = tabs.open(tab: "s7", macID: "mac", at: URL(string: "https://app.example.com/")!) {
            handed.continuation.yield($0)
        }
        var iterator = handed.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(asked == ["mac s7 https://app.example.com/"])
        let cookies = await model.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        #expect(cookies.contains { $0.name == "sid" && $0.value == "abc" })
        #expect(model.url == URL(string: "https://app.example.com/"))
    }

    @Test func aMacThatHandsNothingOpensAsBefore() {
        let tabs = NativeBrowserTabs(defaults: UserDefaults(suiteName: "site-data-\(UUID())")!)
        var asked = false
        tabs.siteData = { _, _, _ in asked = true; return nil }
        let model = tabs.open(tab: "s7", macID: "mac", at: URL(string: "https://app.example.com/")!)
        #expect(!asked, "the Mac does not list site-data-handoff-v1")
        #expect(model.url == URL(string: "https://app.example.com/"))
    }
}
#endif
