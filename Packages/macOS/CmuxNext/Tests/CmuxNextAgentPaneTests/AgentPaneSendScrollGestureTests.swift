import Testing
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextAgentPane

@Suite(.serialized)
@MainActor
struct AgentPaneSendScrollGestureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func legacyPageScriptCannotWriteTheUserOnlySettingWithoutAGesture() async throws {
        let gestures = AgentPaneUserGestures(now: { 100 })
        let model = AgentPaneModel(host: NoHost(), transport: AgentPaneTransport(gestures: gestures))
        var writes = 0
        model.onComposerSetting = { _, _ in writes += 1 }

        let request = AgentPaneRequest.composerSetting(path: AgentPaneComposerSetting.scrollToBottomOnSendPath, show: false)
        let refused = await model.respond(to: request)
        #expect(refused["ok"] as? Bool == false)
        let error = refused["error"] as? [String: Any]
        #expect(error?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(writes == 0)

        gestures.record(click: true)
        let accepted = await model.respond(to: request)
        #expect(accepted["ok"] as? Bool == true)
        #expect(writes == 1)
    }

    @Test func sharedPageHostRejectsTheSettingWithoutItsUserGestureContext() async throws {
        let provider = AgentPageProvider { _ in nil }
        let params: JSONValue = .object(["show": .bool(false)])
        do {
            _ = try await provider.call(
                AgentPageOps.namespace + "pane.setScrollToBottomOnSend",
                params: params,
                context: PageCallContext(page: PageDescriptor.agent.id),
            )
            Issue.record("a script page call unexpectedly changed a user-only setting")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
    }

    @Test func sharedPageHostPassesTheSettingWithItsGestureAndPaneCredit() async throws {
        // The shared PageRouter's authenticated context is the authorization. It renews after a
        // native menu choice even when the menu was open longer than the legacy 30-second credit.
        let model = AgentPaneModel(host: NoHost())
        var writes = 0
        model.onComposerSetting = { _, _ in writes += 1 }
        let provider = AgentPageProvider { _ in model }
        let result = try await provider.call(
            AgentPageOps.namespace + "pane.setScrollToBottomOnSend",
            params: .object(["show": .bool(false)]),
            context: PageCallContext(page: PageDescriptor.agent.id, userGesture: true, gestureEvent: 100),
        )
        #expect(result == .null)
        #expect(writes == 1)
    }
}
