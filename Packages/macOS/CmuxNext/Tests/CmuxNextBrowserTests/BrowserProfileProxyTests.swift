@testable import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// Per-profile proxies (#24432): a profile's proxy goes to both engines, and a
/// profile without one stays direct. Chromium gets one fixed server (no
/// direct fallback, so a dead proxy fails closed); WebKit gets one proxy
/// configuration on the profile's data store, also on a store made earlier.
@MainActor @Suite struct BrowserProfileProxyTests {
    struct Stores: WebsiteDataStoreFactory {
        func makeStore(identifier: UUID) -> WKWebsiteDataStore { .nonPersistent() }
        func removeStore(identifier: UUID) async throws {}
    }

    @Test(arguments: [
        (BrowserProfileProxy.Scheme.socks5, "socks5://127.0.0.1:1080"),
        (.http, "http://127.0.0.1:1080"),
        (.https, "https://127.0.0.1:1080"),
    ])
    func chromiumGetsOneFixedServer(scheme: BrowserProfileProxy.Scheme, server: String) {
        let proxy = BrowserProfileProxy(scheme: scheme, host: "127.0.0.1", port: 1080)
        #expect(proxy.chromiumServer == server)
        #expect(proxy.chromiumBypassList == "")
    }

    @Test func theBypassListJoinsForChromium() {
        let proxy = BrowserProfileProxy(scheme: .http, host: "gw.test", port: 8080, bypass: ["*.corp.test", "10.0.0.0/8"])
        #expect(proxy.chromiumBypassList == "*.corp.test;10.0.0.0/8")
        #expect(BrowserProfileProxy(scheme: .http, host: "::1", port: 8080).chromiumServer == "http://[::1]:8080")
    }

    @Test func aStoreMadeAfterTheProxyIsSetUsesIt() {
        let profile = BrowserProfileID(rawValue: UUID())
        let store = WebKitProfileStore(factory: Stores(), offTheRecord: OffTheRecordProfiles())
        store.setProxy(BrowserProfileProxy(scheme: .socks5, host: "127.0.0.1", port: 1080), for: profile)
        #expect(store.dataStore(for: profile).proxyConfigurations.count == 1)
        // Another profile stays direct.
        #expect(store.dataStore(for: BrowserProfileID(rawValue: UUID())).proxyConfigurations.isEmpty)
    }

    @Test func aLiveStoreFollowsTheProxyAndClearsBackToDirect() {
        let profile = BrowserProfileID(rawValue: UUID())
        let store = WebKitProfileStore(factory: Stores(), offTheRecord: OffTheRecordProfiles())
        let live = store.dataStore(for: profile)
        #expect(live.proxyConfigurations.isEmpty)
        store.setProxy(BrowserProfileProxy(scheme: .http, host: "127.0.0.1", port: 8080), for: profile)
        #expect(live.proxyConfigurations.count == 1)
        store.setProxy(nil, for: profile)
        #expect(live.proxyConfigurations.isEmpty)
    }
}
