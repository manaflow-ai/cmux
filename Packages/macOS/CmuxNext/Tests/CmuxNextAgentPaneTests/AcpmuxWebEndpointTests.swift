import Foundation
import Testing
@testable import CmuxNextAgentPane

/// acpmux reports its dashboard link with the token in the fragment, which a browser never sends to
/// a server; an older acpmux put it in the query. Either way the WebSocket URL carries no token.
struct AcpmuxWebEndpointTests {
    @Test func theTokenComesFromTheFragmentAndLeavesTheURL() throws {
        let endpoint = try #require(AcpmuxWebEndpoint(webURL: "http://127.0.0.1:4567/#token=abc123"))
        #expect(endpoint.token == "abc123")
        #expect(endpoint.url.absoluteString == "ws://127.0.0.1:4567/")
    }

    @Test func anOlderDaemonsQueryTokenStillParses() throws {
        let endpoint = try #require(AcpmuxWebEndpoint(webURL: "http://localhost:4567/?token=abc123"))
        #expect(endpoint.token == "abc123")
        #expect(endpoint.url.absoluteString == "ws://localhost:4567/")
    }

    @Test func aLinkWithoutATokenOrOffLoopbackIsRefused() {
        #expect(AcpmuxWebEndpoint(webURL: "http://127.0.0.1:4567/") == nil)
        #expect(AcpmuxWebEndpoint(webURL: "http://127.0.0.1:4567/#token=") == nil)
        #expect(AcpmuxWebEndpoint(webURL: "http://example.com:4567/#token=abc") == nil)
    }
}
