import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AcpmuxWebEndpointTests {
    @Test func splitsTheDashboardURLIntoAWebSocketAndAToken() throws {
        let endpoint = try #require(AcpmuxWebEndpoint(webURL: "http://127.0.0.1:47811/?token=abc123"))
        #expect(endpoint.url.absoluteString == "ws://127.0.0.1:47811/")
        #expect(endpoint.token == "abc123")
    }

    @Test func keepsOtherQueryItemsAndMapsHTTPSToWSS() throws {
        let endpoint = try #require(AcpmuxWebEndpoint(webURL: "https://localhost:9000?view=x&token=t"))
        #expect(endpoint.url.absoluteString == "wss://localhost:9000/?view=x")
        #expect(endpoint.token == "t")
    }

    @Test func refusesAnythingButATokenOnLoopback() {
        #expect(AcpmuxWebEndpoint(webURL: "http://127.0.0.1:47811/") == nil)
        #expect(AcpmuxWebEndpoint(webURL: "http://127.0.0.1:47811/?token=") == nil)
        #expect(AcpmuxWebEndpoint(webURL: "http://example.com:47811/?token=abc") == nil)
        #expect(AcpmuxWebEndpoint(webURL: "file:///tmp/x?token=abc") == nil)
    }

    @Test func parsesTheReadyLine() throws {
        let line = #"{"ready":true,"pid":42,"socket":"/tmp/a.sock","listen":"127.0.0.1:5000","webUrl":"http://127.0.0.1:5000/?token=z"}"#
        let ready = try #require(AcpmuxReadyLine.parse(line))
        #expect(ready.pid == 42)
        #expect(ready.webUrl == "http://127.0.0.1:5000/?token=z")
        #expect(AcpmuxReadyLine.parse(#"{"ready":false}"#) == nil)
        #expect(AcpmuxReadyLine.parse("error: unexpected argument '--ready-fd'") == nil)
    }

    @Test func findsTheStatusReplyAmongOtherMessages() throws {
        let notification = Data(#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{}}"#.utf8)
        #expect(try AcpmuxStatusClient.reply(to: 2, in: notification) == nil)
        let initialize = Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#.utf8)
        #expect(try AcpmuxStatusClient.reply(to: 2, in: initialize) == nil)
        let status = Data(#"{"jsonrpc":"2.0","id":2,"result":{"webUrl":"http://127.0.0.1:1/?token=t"}}"#.utf8)
        #expect(try AcpmuxStatusClient.reply(to: 2, in: status)?["webUrl"] as? String == "http://127.0.0.1:1/?token=t")
        let failure = Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"no such method"}}"#.utf8)
        #expect(throws: AcpmuxStatusClient.Failure.rpc("no such method")) { try AcpmuxStatusClient.reply(to: 2, in: failure) }
    }
}
