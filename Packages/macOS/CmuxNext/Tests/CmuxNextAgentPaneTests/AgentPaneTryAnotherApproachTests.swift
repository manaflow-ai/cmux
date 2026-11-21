import Foundation
import Testing

@testable import CmuxNextAgentPane

@Suite struct AgentPaneTryAnotherApproachTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class CallBox { var calls: [(Int, String)] = [] }

    @Test func decodesOnlyPositiveTurnSequences() {
        #expect(AgentPaneRequest(body: ["method": "chat.tryAnotherApproach", "params": ["throughSeq": 6]])
            == .tryAnotherApproach(.init(params: ["throughSeq": 6])!))
        #expect(AgentPaneRequest(body: ["method": "chat.tryAnotherApproach", "params": ["throughSeq": 0]])
            == .unsupported("chat.tryAnotherApproach"))
        #expect(AgentPaneRequest(body: ["method": "chat.tryAnotherApproach", "params": ["throughSeq": 6, "extra": true]])
            == .unsupported("chat.tryAnotherApproach"))
        for loose: Any in [6.5, true, "6"] {
            #expect(AgentPaneRequest(body: ["method": "chat.tryAnotherApproach", "params": ["throughSeq": loose]])
                == .unsupported("chat.tryAnotherApproach"))
        }
    }

    /// A machine snapshot plus a durable sibling chat: page script alone never starts one, and the
    /// fork names the session the pane showed when the click arrived.
    @Test @MainActor func onlyThePersonsClickForksAndItNamesThePanesSession() async {
        let gestures = AgentPaneUserGestures(now: { 100 })
        let model = AgentPaneModel(host: NoHost(), sessionId: "parent-session", transport: AgentPaneTransport(gestures: gestures))
        model.remoteChat = true
        let box = CallBox()
        model.onTryAnotherApproach = { seq, session in
            box.calls.append((seq, session))
            return ["childSession": "child"]
        }
        let request = AgentPaneRequest.tryAnotherApproach(.init(params: ["throughSeq": 6])!)

        let refused = await model.respond(to: request)
        #expect(refused["ok"] as? Bool == false)
        #expect((refused["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(box.calls.isEmpty)

        gestures.record(click: true)
        let accepted = await model.respond(to: request)
        #expect(accepted["ok"] as? Bool == true)
        #expect(box.calls.map(\.0) == [6])
        #expect(box.calls.map(\.1) == ["parent-session"])

        // The credit is one-use: a second page call with no new click is refused.
        let again = await model.respond(to: request)
        #expect(again["ok"] as? Bool == false)
        #expect(box.calls.count == 1)

        // The host's authenticated click counts by itself.
        let hosted = await model.respond(to: request, userGesture: true)
        #expect(hosted["ok"] as? Bool == true)
        #expect(box.calls.count == 2)
    }
}
