@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The missing-access card's host calls (paid-plan.md section 4): `access.addKey` (the native API
/// key sheet), `credits.state`, `credits.topup` and `credits.wait`. The page never sends a key; a
/// sheet or a payment page opens only on the person's click.
@MainActor
struct AgentPaneAccessRequestTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// What the App's provider was asked.
    private final class Provider: AgentPaneAccessProviding {
        var asked: [AgentPaneAccessRequest] = []
        func respond(to request: AgentPaneAccessRequest, acpmuxSocket: String?) async -> AgentPaneAccessReply {
            asked.append(request)
            return .success(["routeId": .string("apikey-anthropic")])
        }
    }

    private static func request(_ method: String, _ params: [String: Any] = [:]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test func theCallsDecodeAndAKeyOrUnknownParamIsRefused() {
        #expect(Self.request("access.addKey", ["harness": "claude", "family": "claude"]) == .access(.addKey(harness: "claude", family: "claude")))
        #expect(Self.request("credits.state") == .access(.creditsState))
        #expect(Self.request("credits.topup", ["usd": 20]) == .access(.creditsTopUp(usd: 20)))
        #expect(Self.request("credits.wait", ["above": 0.4, "session": "cs_test_a1"]) == .access(.creditsWait(above: 0.4, session: "cs_test_a1")))
        // The key never comes from the page.
        #expect(Self.request("access.addKey", ["harness": "claude", "key": "sk-ant-x"]) == .unsupported("access.addKey"))
        #expect(Self.request("access.addKey", ["harness": "claude && rm"]) == .unsupported("access.addKey"))
        #expect(Self.request("credits.topup", ["usd": "20"]) == .unsupported("credits.topup"))
        #expect(Self.request("credits.topup", ["usd": 0]) == .unsupported("credits.topup"))
    }

    @Test func aSheetOrACheckoutOpensOnlyOnTheClick() async {
        let model = AgentPaneModel(host: NoHost())
        let provider = Provider()
        model.access = provider
        let refused = await model.respond(to: Self.request("access.addKey", ["harness": "claude"]))
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "access.gesture_required")
        let topUp = await model.respond(to: Self.request("credits.topup", ["usd": 20]))
        #expect((topUp["error"] as? [String: Any])?["code"] as? String == "access.gesture_required")
        #expect(provider.asked.isEmpty)
        model.transport.gestures.record()
        let answered = await model.respond(to: Self.request("access.addKey", ["harness": "claude"]))
        #expect((answered["value"] as? [String: Any])?["routeId"] as? String == "apikey-anthropic")
        // Reading the balance and waiting for it take no gesture.
        _ = await model.respond(to: Self.request("credits.state"))
        _ = await model.respond(to: Self.request("credits.wait", ["above": 1]))
        #expect(provider.asked == [.addKey(harness: "claude", family: nil), .creditsState, .creditsWait(above: 1, session: nil)])
    }

    @Test func withoutTheAppsProviderEachCallIsUnsupported() async {
        let model = AgentPaneModel(host: NoHost())
        let reply = await model.respond(to: Self.request("credits.state"))
        #expect(reply["ok"] as? Bool == false)
    }
}
