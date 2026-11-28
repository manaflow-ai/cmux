#if os(iOS)
import Foundation
import CmuxMobileBrowserStream
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

    /// Each handoff owns a distinct cookie name and origin, even when tests share
    /// the ordinary WebKit store. No network page load is needed to inspect these.
    private func frame(for url: URL, marker: String, includesCookie: Bool = true) throws -> Data {
        let host = try #require(url.host)
        let origin = "\(url.scheme!)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        let cookies: [[String: Any]] = includesCookie ? [[
            "name": marker, "value": "handed", "domain": host, "path": "/",
            "secure": false, "http_only": false,
        ]] : []
        return try JSONSerialization.data(withJSONObject: [
            "v": 1, "site": host, "cookies": cookies,
            "local_storage": [["origin": origin, "items": [[marker, "stored"]]]],
        ])
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test(arguments: [false, true])
    func handoffFollowsTheDestinationStoreWhenCrossingOrdinaryAndPrivateViews(privateFirst: Bool) async throws {
        let marker = "handoff-\(UUID().uuidString)"
        let tabs = NativeBrowserTabs(defaults: UserDefaults(suiteName: marker)!)
        let forwarder = LocalhostForwarder(openHost: { _, _, _ in
            DevServerChannel(page: "<title>Handoff destination</title>")
        })
        tabs.forwarder = forwarder
        tabs.macForwardsPrivateHost = { _ in true }
        defer { forwarder.retain(proxies: []) }
        let privateURL = try #require(URL(string: "http://\(marker).local:8080/page"))
        let ordinaryURL = try #require(URL(string: "https://\(marker).example.test/page"))
        let model = tabs.open(tab: "handoff", macID: "mac", at: nil)
        let ordinary = model.webView
        if privateFirst {
            tabs.open(tab: "handoff", macID: "mac", at: privateURL)
            await until { model.webView !== ordinary }
            try #require(model.webView !== ordinary)
        }
        let previous = model.webView
        let destinationURL = privateFirst ? ordinaryURL : privateURL
        let payload = try frame(for: destinationURL, marker: marker)
        tabs.macHandsSiteData = { _ in true }
        tabs.siteData = { _, _, _ in payload }
        var results: [Bool] = []
        let reopened = tabs.open(tab: "handoff", macID: "mac", at: destinationURL) { results.append($0) }
        #expect(reopened === model)
        await until { !results.isEmpty }
        #expect(results == [true])
        let destination = model.webView
        #expect(destination !== previous)
        #expect((destination === ordinary) == privateFirst)
        #expect(destination.configuration.websiteDataStore !== previous.configuration.websiteDataStore)
        let destinationCookies = await destination.configuration.websiteDataStore.httpCookieStore.allCookies()
        let previousCookies = await previous.configuration.websiteDataStore.httpCookieStore.allCookies()
        #expect(destinationCookies.contains { $0.name == marker && $0.value == "handed" })
        #expect(!previousCookies.contains { $0.name == marker }, "handoff must not write into the page being left")
        #expect(destination.configuration.userContentController.userScripts.contains { $0.source.contains(marker) })
        #expect(!previous.configuration.userContentController.userScripts.contains { $0.source.contains(marker) })
        #expect(model.url == destinationURL)
        // Remove only this test's cookie from the shared or isolated store.
        for view in [destination, previous] {
            for cookie in await view.configuration.websiteDataStore.httpCookieStore.allCookies() where cookie.name == marker {
                await view.configuration.websiteDataStore.httpCookieStore.delete(cookie)
            }
        }
        _ = tabs.close(tab: "handoff", macID: "mac")
    }

    @Test(arguments: ["navigation", "mirror", "mirror-reopen"])
    func delayedSiteDataCannotReviveAnObsoleteOpenOnIPhone(action: String) async throws {
        let marker = "stale-handoff-\(UUID().uuidString)"
        let tabs = NativeBrowserTabs(defaults: UserDefaults(suiteName: marker)!)
        let obsolete = try #require(URL(string: "https://\(marker).example.test/obsolete"))
        // No cookie-store await obscures the ordering under test: this valid
        // handoff still installs a storage script and would report success.
        let payload = try frame(for: obsolete, marker: marker, includesCookie: false)
        var pending: CheckedContinuation<Data?, Never>?
        var returned = false
        var results: [Bool] = []
        tabs.macHandsSiteData = { _ in true }
        tabs.siteData = { _, _, _ in
            let data = await withCheckedContinuation { pending = $0 }
            returned = true
            return data
        }
        let model = tabs.open(tab: "handoff", macID: "mac", at: obsolete) { results.append($0) }
        await until { pending != nil }
        let continuation = try #require(pending)
        if action == "navigation" {
            model.load(URL(string: "about:blank")!)
        } else {
            _ = tabs.close(tab: "handoff", macID: "mac")
            if action == "mirror-reopen" {
                tabs.macHandsSiteData = { _ in false }
                tabs.open(tab: "handoff", macID: "mac", at: URL(string: "about:blank"))
            }
        }
        let currentURL = model.url
        let currentView = model.webView
        continuation.resume(returning: payload)
        await until { returned }
        for _ in 0..<20 { await Task.yield() }
        #expect(returned)
        #expect(results.isEmpty, "an obsolete handoff cannot report success or failure for the new page")
        #expect(model.url == currentURL)
        #expect(model.webView === currentView)
        #expect(!currentView.configuration.userContentController.userScripts.contains { $0.source.contains(marker) })
        #expect(currentView.backForwardList.currentItem?.url != obsolete)
        _ = tabs.close(tab: "handoff", macID: "mac")
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
