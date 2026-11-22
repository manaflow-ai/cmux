import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ad349, round 6: the relay rewrites the id of every request it forwards to an id it owns, maps
/// the reply back (and filters it by the request's method), refuses a page request whose id (JSON
/// value and type) is still in flight, and drops a daemon reply whose id it did not send.
@MainActor
@Suite(.serialized) struct AgentPaneRequestIdTests {
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#
    nonisolated static let dirty = #"{"webUrl":"http://127.0.0.1:4700/?token=secret-web","token":"secret-token","peers":[{"name":"studio"}]}"#

    final class Rig {
        let server = AcpmuxStandInServer()
        let transport = AgentPaneTransport()
        var received: [String] = []
        var connection = 0

        func start() async throws {
            try await server.start()
            server.answer("_acpmux/status", with: AgentPaneRequestIdTests.dirty)
            server.answer("_acpmux/harnesses", with: #"{"harnesses":[{"id":"claude"}],"webUrl":"harness-reply"}"#)
            transport.deliver = { [weak self] event, done in self?.received += event.frames; done() }
            connection = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
            _ = await transport.send(connection: connection, frames: [AgentPaneRequestIdTests.initialize])
            // Until its reply, the initialize's relay id is in flight (and a reply to it is real).
            await settle { !replies("0").isEmpty }
        }

        func send(_ id: String, _ method: String) async -> AgentPaneTransportError? {
            await transport.send(connection: connection, frames: [#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":{}}"#])
        }

        /// The replies the page got, by their raw id.
        func replies(_ id: String) -> [String] {
            received.filter { text in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      object["method"] == nil, let value = object["id"] else { return false }
                return AcpmuxPaneMethods.rawID(value) == id
            }
        }

        func settle(until condition: () -> Bool) async {
            for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    @Test func theDaemonSeesOnlyRelayIds() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        #expect(await rig.send(#""page-id""#, "_acpmux/harnesses") == nil)
        await rig.settle { !rig.replies(#""page-id""#).isEmpty }
        #expect(rig.replies(#""page-id""#).count == 1)
        #expect(rig.server.peers.last?.frames.contains { $0.contains("page-id") } == false)
    }

    @Test func aRequestWhoseIdIsInFlightIsRefused() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        rig.server.hold("_acpmux/status")
        #expect(await rig.send("7", "_acpmux/status") == nil)
        #expect(await rig.send("7", "_acpmux/harnesses") == .requestIdInFlight)
        // Another type is another id.
        #expect(await rig.send(#""7""#, "_acpmux/harnesses") == nil)
        rig.server.releaseHeld()
        await rig.settle { !rig.replies("7").isEmpty }
        // Once answered, the id may be used again.
        #expect(await rig.send("7", "_acpmux/harnesses") == nil)
    }

    /// The status request is held, a harnesses request with the same id (after the first is
    /// answered) or the same digits as a string is answered first: no webUrl reaches the page.
    @Test func aStatusReplyIsFilteredWhateverIsAnsweredFirst() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        rig.server.hold("_acpmux/status")
        #expect(await rig.send("7", "_acpmux/status") == nil)
        // The same id again: answered first, it must not take the status request's place.
        _ = await rig.send("7", "_acpmux/harnesses")
        #expect(await rig.send(#""7""#, "_acpmux/harnesses") == nil)
        await rig.settle { !rig.replies(#""7""#).isEmpty }
        rig.server.releaseHeld()
        await rig.settle { rig.replies("7").contains { $0.contains("studio") } }
        let status = try #require(rig.replies("7").first { $0.contains("studio") })
        #expect(!status.contains("secret") && !status.contains("webUrl"), "\(status)")
        #expect(status.contains("studio"))
        // The harnesses reply is not filtered and keeps its own id.
        #expect(rig.replies(#""7""#).first?.contains("harness-reply") == true)
        #expect(!rig.received.contains { $0.contains("secret") })
    }

    @Test func aReplyWithAnIdTheRelayDidNotSendIsDropped() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        for id in ["4242", #""7""#, "0", "null", "1"] {
            rig.server.push(#"{"jsonrpc":"2.0","id":\#(id),"result":{"webUrl":"http://x/?token=secret-unsolicited"}}"#, to: 0)
        }
        // A daemon notification still passes.
        rig.server.push(#"{"jsonrpc":"2.0","method":"session/update","params":{"marker":"m-1"}}"#, to: 0)
        await rig.settle { rig.received.contains { $0.contains("m-1") } }
        #expect(rig.received.contains { $0.contains("m-1") })
        #expect(!rig.received.contains { $0.contains("secret") })
    }

    /// R1 runs before the early return that leaves a redeeming frame's _meta to the gesture rule.
    @Test func aRedeemingFramesOtherMetaIsRefusedByTheParamsRuleItself() {
        func frame(_ meta: [String: Any]) -> [String: Any] {
            ["method": "session/set_config_option", "params": ["sessionId": "s", "configId": "effort", "value": "high", "_meta": meta]]
        }
        #expect(!AcpmuxPaneMethods.breaksParamsRule(frame(["cmuxGesture": "t"]), modeFields: []))
        #expect(AcpmuxPaneMethods.breaksParamsRule(frame(["cmuxGesture": "t", "acpmux": ["permissionMode": "x"]]), modeFields: []))
        #expect(AcpmuxPaneMethods.breaksParamsRule(frame(["cmuxGesture": "t", "claudeCode": [:]]), modeFields: nil))
        #expect(AcpmuxPaneMethods.breaksParamsRule(frame(["cmuxGesture": "t", "acpmux": [:]]), modeFields: nil))
    }

    /// A question card answers with `answers` (plans/cmux-next/agent-questions.md): the params rule
    /// lets it through and, as an allow, it still needs a fresh user gesture.
    @Test func aQuestionAnswerPassesTheParamsRuleAndNeedsAGesture() {
        let frame: [String: Any] = ["method": "_acpmux/permission_respond", "params": [
            "sessionId": "s", "permissionId": "p1", "optionId": "allow_once", "answers": ["Which one?": "B"],
        ]]
        #expect(!AcpmuxPaneMethods.breaksParamsRule(frame, modeFields: []))
        #expect(AcpmuxPaneMethods.needsGesture(frame, options: AcpmuxPermissionOptions()))
        let extra: [String: Any] = ["method": "_acpmux/permission_respond", "params": [
            "sessionId": "s", "permissionId": "p1", "optionId": "allow_once", "updatedInput": ["x": 1],
        ]]
        #expect(AcpmuxPaneMethods.breaksParamsRule(extra, modeFields: []))
    }
}
