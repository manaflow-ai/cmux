import Foundation
import Testing
@testable import CmuxNextAgentPane

private actor AccountNoHost: AgentPaneHostProviding {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
}

@Suite(.serialized)
@MainActor
struct AgentPaneAddAccountTests {
    private let params: [String: String] = ["id": "work", "kind": "direct-subscription", "name": "Work login", "accountHome": "/tmp/account-work"]

    @Test func decodesTypedRequestWithoutLoggingAccountDetails() {
        let request = AgentPaneRequest(body: ["method": "account.add", "params": params])
        #expect(request.description == "addAccount")
        #expect(!String(reflecting: request).contains("account-work"))
        #expect(AgentPaneRequest(body: ["method": "account.add", "params": params.merging(["replace": "true"]) { _, value in value }]).description == "unsupported")
        #expect(AgentPaneRequest(body: ["method": "account.add", "params": ["id": "work", "kind": 1]]).description == "unsupported")
    }

    @Test func onlyOneRealGestureForwardsTheTypedAddThroughTheLocalSocket() async throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).sock").path
        let relay = try OneShotRelay(path: socket, replies: [
            #"{"jsonrpc":"2.0","id":1,"result":{"_meta":{"acpmux":{"origin":"local"}}}}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{"id":"work","kind":"direct-subscription","name":"Work login"}}"#,
        ])
        defer { relay.stop() }
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let model = AgentPaneModel(host: AccountNoHost(), sessionId: "session-1")
        let connection = try await model.transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil, socketPath: socket))
        defer { model.transport.close(connection: connection) }
        let request = AgentPaneRequest(body: ["method": "account.add", "params": params])
        let refused = await model.respond(to: request)
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "transport.gesture_required")
        #expect(relay.requests.isEmpty)
        model.transport.gestures.record(click: true)
        let added = await model.respond(to: request)
        #expect((added["value"] as? [String: Any])?["id"] as? String == "work")
        let calls = relay.requests.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let add = try #require(calls.first { $0["method"] as? String == "_acpmux/route/add" })
        #expect(add["params"] as? [String: String] == params)
        #expect(!model.transport.gestures.isAvailable)
        let replayed = await model.respond(to: request)
        #expect((replayed["error"] as? [String: Any])?["code"] as? String == "transport.gesture_required")
    }

    @Test func remoteChatCannotCreateLocalAccounts() async {
        let model = AgentPaneModel(host: AccountNoHost(), sessionId: "session-1")
        model.remoteChat = true
        model.transport.gestures.record(click: true)
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "account.add", "params": params]))
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupported")
        #expect(model.transport.gestures.isAvailable)
    }

    @Test func routeMutationStillCannotUseTheWebSocketTransport() {
        let frame = #"{"jsonrpc":"2.0","id":1,"method":"_acpmux/route/add","params":{"id":"work","kind":"direct-subscription"}}"#
        if case .send = AcpmuxPaneMethods.decide(frame, isFirst: false, localAppToken: nil) {
            Issue.record("route/add must remain off the page transport allowlist")
        }
    }
}
