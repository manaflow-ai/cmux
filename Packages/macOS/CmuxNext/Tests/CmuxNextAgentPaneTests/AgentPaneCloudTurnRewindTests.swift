import Foundation
import Testing

@testable import CmuxNextAgentPane

@Suite struct AgentPaneCloudTurnRewindTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class CallBox { var calls: [(AgentPaneCloudTurnRewind, String)] = [] }

    @Test func decodesOnlyWholeTurnNumbers() {
        #expect(AgentPaneRequest(body: ["method": "chat.turnCheckpoint", "params": ["afterSeq": 6]])
            == .cloudTurnRewind(.checkpoint(afterSeq: 6)))
        // The checkpoint before the first turn is after "turn 0".
        #expect(AgentPaneRequest(body: ["method": "chat.turnCheckpoint", "params": ["afterSeq": 0]])
            == .cloudTurnRewind(.checkpoint(afterSeq: 0)))
        #expect(AgentPaneRequest(body: ["method": "chat.rewindTurn", "params": ["turnSeq": 7]])
            == .cloudTurnRewind(.rewind(turnSeq: 7)))
        #expect(AgentPaneRequest(body: ["method": "chat.rewindTurn", "params": ["turnSeq": 0]])
            == .unsupported("chat.rewindTurn"))
        // The page's Back to before this turn names the sent prompt's row (`user-<seq>`).
        #expect(AgentPaneRequest(body: ["method": "chat.rewindTurn", "params": ["rowId": "user-42"]])
            == .cloudTurnRewind(.rewind(turnSeq: 42)))
        for row in ["user-0", "user-042", "user-", "assistant-42", "user-4x", "user-1234567890123456", "user-٤٢"] {
            #expect(AgentPaneRequest(body: ["method": "chat.rewindTurn", "params": ["rowId": row]])
                == .unsupported("chat.rewindTurn"), "\(row)")
        }
        #expect(AgentPaneRequest(body: ["method": "chat.rewindTurn", "params": ["rowId": "user-4", "turnSeq": 4]])
            == .unsupported("chat.rewindTurn"))
        #expect(AgentPaneCloudTurnRewind.rowID(turnSeq: 42) == "user-42")
        #expect(AgentPaneRequest(body: ["method": "chat.turnCheckpoint", "params": ["afterSeq": -1]])
            == .unsupported("chat.turnCheckpoint"))
        #expect(AgentPaneRequest(body: ["method": "chat.turnCheckpoint", "params": ["afterSeq": 6, "extra": true]])
            == .unsupported("chat.turnCheckpoint"))
        #expect(AgentPaneRequest(body: ["method": "chat.rewindTurn", "params": ["afterSeq": 6]])
            == .unsupported("chat.rewindTurn"))
        for loose: Any in [6.5, true, "6"] {
            #expect(AgentPaneRequest(body: ["method": "chat.rewindTurn", "params": ["turnSeq": loose]])
                == .unsupported("chat.rewindTurn"))
            #expect(AgentPaneRequest(body: ["method": "chat.turnCheckpoint", "params": ["afterSeq": loose]])
                == .unsupported("chat.turnCheckpoint"))
        }
    }

    /// A checkpoint and a rewind name the same turn: the one after completed turn `afterSeq`.
    @Test func aCheckpointAndItsRewindNameOneTurn() {
        #expect(AgentPaneCloudTurnRewind.checkpoint(afterSeq: 6).turnSeq == 7)
        #expect(AgentPaneCloudTurnRewind.rewind(turnSeq: 7).turnSeq == 7)
        #expect(AgentPageOps.method(for: "cmux.agent.chat.turnCheckpoint") == "chat.turnCheckpoint")
        #expect(AgentPageOps.method(for: "cmux.agent.chat.rewindTurn") == "chat.rewindTurn")
    }

    /// The checkpoint follows a completed turn on its own; the rewind replaces the machine, so only
    /// the person's click starts one. Both name the session the pane showed when the call arrived.
    @Test @MainActor func onlyAClickRewindsAndBothNameThePanesSession() async {
        let gestures = AgentPaneUserGestures(now: { 100 })
        let model = AgentPaneModel(host: NoHost(), sessionId: "cloud-session", transport: AgentPaneTransport(gestures: gestures))
        model.remoteChat = true
        let box = CallBox()
        model.onCloudTurnRewind = { request, session in
            box.calls.append((request, session))
            return ["turnSeq": request.turnSeq]
        }

        let checkpoint = await model.respond(to: .cloudTurnRewind(.checkpoint(afterSeq: 3)))
        #expect(checkpoint["ok"] as? Bool == true)
        #expect(box.calls.map(\.0) == [.checkpoint(afterSeq: 3)])
        #expect(box.calls.map(\.1) == ["cloud-session"])

        let rewind = AgentPaneRequest(body: ["method": "chat.rewindTurn", "params": ["rowId": "user-4"]])
        let refused = await model.respond(to: rewind)
        #expect(refused["ok"] as? Bool == false)
        #expect((refused["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(box.calls.count == 1)

        gestures.record(click: true)
        let accepted = await model.respond(to: rewind)
        #expect(accepted["ok"] as? Bool == true)
        #expect(box.calls.last?.0 == .rewind(turnSeq: 4))

        let hosted = await model.respond(to: rewind, userGesture: true)
        #expect(hosted["ok"] as? Bool == true)
        #expect(box.calls.count == 3)
    }

    /// The ready handshake names the rows as a list, and only when the host set one.
    @Test func theHandshakeCarriesTheReadyRows() throws {
        var handshake = AgentPaneHandshake.mock
        let without = try JSONSerialization.jsonObject(with: JSONEncoder().encode(handshake)) as? [String: Any]
        #expect(without?["cloudTurnRewind"] == nil)
        handshake.cloudTurnRewind = ["user-4", "user-9"]
        let with = try JSONSerialization.jsonObject(with: JSONEncoder().encode(handshake)) as? [String: Any]
        #expect(with?["cloudTurnRewind"] as? [String] == ["user-4", "user-9"])
    }

    /// Off (no callback: signed out, not a Cloud chat or `cloud.turnCheckpoints` off) or a local chat: unsupported.
    @Test @MainActor func aLocalChatOrTheSettingOffIsUnsupported() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "s", transport: AgentPaneTransport(gestures: AgentPaneUserGestures(now: { 100 })))
        model.remoteChat = true
        let off = await model.respond(to: .cloudTurnRewind(.checkpoint(afterSeq: 1)))
        #expect(off["ok"] as? Bool == false)
        model.onCloudTurnRewind = { _, _ in ["ok": true] }
        model.remoteChat = false
        let local = await model.respond(to: .cloudTurnRewind(.checkpoint(afterSeq: 1)))
        #expect(local["ok"] as? Bool == false)
    }
}
