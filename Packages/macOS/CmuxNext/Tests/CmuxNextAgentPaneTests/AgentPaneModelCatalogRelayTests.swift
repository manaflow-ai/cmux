import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The model picker's catalog at the relay boundary (the page's frames into ``AgentPaneTransport``, out to
/// acpmux). direct.ts `modelCatalog` sends `catalog.refresh {}` then `catalog.get {}` (ef3e54313f7), but the
/// allow-list never listed them, so every read came back `transport.method_refused` and the picker never
/// learned a model the feed lists. Both go out with no params and no gesture; a param is still refused.
@Suite(.serialized)
@MainActor
struct AgentPaneModelCatalogRelayTests {
    static func frame(id: Int, method: String, params: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
    }

    @Test(arguments: ["catalog.get", "catalog.refresh"])
    func theCatalogReadsReachAcpmux(_ method: String) async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        let sent = { server.peers.first?.frames.filter { $0.contains(#""method":"\#(method)""#) } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, method: method, params: #"{"url":"https://x"}"#)]) != nil,
                "a param the pane never sends")
        #expect(sent().isEmpty, "a refused frame reached acpmux: \(sent())")

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, method: method)]) == nil)
        _ = await inbox.frame(containing: #""id":3"#)
        #expect(sent().count == 1, "\(sent())")
    }

    @Test(arguments: ["catalog.get", "catalog.refresh"])
    func theCatalogReadsAreListedAndNeedNoGesture(_ method: String) {
        #expect(AcpmuxPaneMethods.requests.contains(method))
        #expect(!AcpmuxPaneMethods.needsGesture(Self.frame(id: 1, method: method), options: AcpmuxPermissionOptions()))
    }
}
