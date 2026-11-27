import Foundation
import Testing
@testable import CmuxNextAgentPane

private actor AccountNoHost: AgentPaneHostProviding {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
}

@Suite(.serialized)
@MainActor
struct AgentPaneAddAccountTests {
    private let params: [String: String] = ["id": "work", "kind": "direct-subscription", "family": "claude", "name": "Work login", "accountHome": "/tmp/account-work"]

    @Test func decodesTypedRequestWithoutLoggingAccountDetails() {
        let request = AgentPaneRequest(body: ["method": "account.add", "params": params])
        #expect(request.description == "addAccount")
        #expect(!String(reflecting: request).contains("account-work"))
        #expect(AgentPaneRequest(body: ["method": "account.add", "params": params.merging(["replace": "true"]) { _, value in value }]).description == "unsupported")
        #expect(AgentPaneRequest(body: ["method": "account.add", "params": ["id": "work", "kind": 1]]).description == "unsupported")
        #expect(AgentPaneRequest(body: ["method": "account.add", "params": params.filter { $0.key != "family" }]).description == "unsupported")
    }

    @Test(arguments: ["claude", "codex"])
    func onlyOneRealGestureForwardsTheTypedAddThroughTheLocalSocket(family: String) async throws {
        let params = self.params.merging(["family": family]) { _, value in value }
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).sock").path
        let relay = try OneShotRelay(path: socket, replies: [
            #"{"jsonrpc":"2.0","id":1,"result":{"_meta":{"acpmux":{"origin":"local"}}}}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{"id":"work","kind":"direct-subscription","name":"Work login"}}"#,
        ])
        defer { relay.stop() }
        let model = AgentPaneModel(host: AccountNoHost(), sessionId: "session-1")
        model.transport.acpmuxSocket = socket
        let request = AgentPaneRequest(body: ["method": "account.add", "params": params])
        let refused = await model.respond(to: request)
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "transport.gesture_required")
        #expect(relay.requests.isEmpty)
        model.transport.gestures.record(click: true)
        let added = await model.respond(to: request)
        #expect((added["value"] as? [String: Any])?["id"] as? String == "work")
        let calls = relay.requests.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let add = try #require(calls.first { $0["method"] as? String == "_acpmux/route/add" })
        let forwarded = try #require(add["params"] as? [String: Any])
        #expect(forwarded["families"] as? [String] == [family])
        #expect(forwarded["family"] == nil)
        for (key, value) in params where key != "family" { #expect(forwarded[key] as? String == value) }
        #expect(!model.transport.gestures.isAvailable)
        let replayed = await model.respond(to: request)
        #expect((replayed["error"] as? [String: Any])?["code"] as? String == "transport.gesture_required")
    }

    @Test func expandsOnlyAHomeRelativeAccountFolder() {
        #expect(AgentPaneAddAccount.expandedHome("~/.cmux/accounts/chatgpt-2", homeDirectory: "/Users/x")
            == ["accountHome": "/Users/x/.cmux/accounts/chatgpt-2"])
        #expect(AgentPaneAddAccount.expandedHome("/tmp/account-work", homeDirectory: "/Users/x").isEmpty)
        #expect(AgentPaneAddAccount.expandedHome("~/", homeDirectory: "/Users/x").isEmpty)
        #expect(AgentPaneAddAccount.expandedHome("~other/x", homeDirectory: "/Users/x").isEmpty)
        #expect(AgentPaneAddAccount.expandedHome(nil).isEmpty)
        let request = AgentPaneAddAccount(params: params.merging(["accountHome": "~/.cmux/accounts/work"]) { _, value in value })
        #expect(request?.fields["accountHome"] == (NSHomeDirectory() as NSString).appendingPathComponent(".cmux/accounts/work"))
    }

    @Test func aShadowLoginIsAFlagAndNothingElse() {
        let shadow = AgentPaneAddAccount(params: (params as [String: Any]).merging(["shadow": true]) { _, value in value })
        #expect(shadow?.shadow == true)
        #expect(shadow?.fields["shadow"] == nil)
        #expect(AgentPaneAddAccount(params: params)?.shadow == false)
        #expect(AgentPaneAddAccount(params: (params as [String: Any]).merging(["shadow": "yes"]) { _, value in value }) == nil)
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
