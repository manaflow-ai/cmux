import Network
import Testing
import WebKit

@testable import CmuxBrowser

/// `session.configure({ proxy })` gives the session's tabs a private data
/// store whose connections go through the agent's proxy. That proxy is the
/// session's: when the session ends, a tab it kept (now the user's) and
/// every tab still on that store stop using it.
@MainActor
@Suite("Browser REPL proxy stores")
struct BrowserReplProxyStoresTests {
    private static func proxied() -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 8888)
        store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)]
        return store
    }

    @Test func aSessionsProxyEndsWithTheSession() {
        let stores = BrowserReplProxyStores()
        let first = Self.proxied()
        let second = Self.proxied()
        let other = Self.proxied()
        stores.register(first, sessionID: "agent")
        stores.register(second, sessionID: "agent")
        stores.register(other, sessionID: "another")
        #expect(stores.owns(first) && stores.owns(second) && stores.owns(other))

        stores.sessionEnded("agent")
        // The browser's own proxy handling takes the stores back.
        #expect(!stores.owns(first))
        #expect(!stores.owns(second))
        #expect(first.proxyConfigurations.isEmpty, "a kept tab no longer goes through the agent's proxy")
        #expect(second.proxyConfigurations.isEmpty)
        // Another session's proxy is its own.
        #expect(stores.owns(other))
        #expect(other.proxyConfigurations.count == 1)
    }
}
