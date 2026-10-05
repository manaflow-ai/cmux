import Foundation
import Testing
@testable import CmuxNextAgentPane

/// B1 and B2 (ad349) and the intent contract agreed with the ACP UI lead: a gesture ticket is bound
/// to its connection and to one exact pick, is spent even when it does not match, redeems only
/// session/set_mode and session/set_config_option into a session of the pane, and is gone after a
/// newer reserve for the same method, a reconnect, the end of the switch (a sent prompt) or 60 s.
@MainActor
@Suite(.serialized) struct AgentPaneGestureTicketTests {
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#

    final class Rig {
        let server = AcpmuxStandInServer()
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var transport: AgentPaneTransport { model.transport }
        var connection = 0
        var nextID = 100
        /// The daemon's `_acpmux/web_modes` answer (nil: no daemon answer, the fail-closed rule).
        var webModes = AcpmuxAskingModesFake.claude

        func start() async throws {
            try await server.start()
            try await connect()
        }

        func connect() async throws {
            transport.deliver = { _, done in done() }
            transport.webModes = webModes
            connection = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
            _ = await transport.send(connection: connection, frames: [AgentPaneGestureTicketTests.initialize])
            transport.sessions.add("s")
        }

        /// `transport.gesture` with `params`, after a user gesture.
        func reserve(_ params: [String: Any], gesture: Bool = true) async -> [String: Any] {
            if gesture { transport.gestures.record() }
            return await model.respond(to: AgentPaneRequest(body: ["method": "transport.gesture", "params": params]))
        }

        func ticket(_ intent: [String: Any]) async -> String? {
            ((await reserve(["intent": intent]))["value"] as? [String: Any])?["ticket"] as? String
        }

        /// Sends `method` with `params` plus the ticket in `_meta.cmuxGesture`.
        func send(_ method: String, _ params: [String: Any], ticket: String?) async -> AgentPaneTransportError? {
            nextID += 1
            var params = params
            if let ticket { params["_meta"] = ["cmuxGesture": ticket] }
            let object: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            return await transport.send(connection: connection, frames: [text])
        }
    }

    static let mode: [String: Any] = ["method": "session/set_mode", "params": ["modeId": "default"]]
    static let effort: [String: Any] = ["method": "session/set_config_option", "params": ["configId": "thinking", "value": true]]

    @Test func theIntentContractIsExact() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        func code(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }
        let invalid: [[String: Any]] = [
            [:],
            ["intent": ["params": ["modeId": "x"]]],
            ["intent": ["method": "session/prompt", "params": [:]]],
            ["intent": ["method": "session/set_mode", "params": ["modeId": "x", "extra": 1]]],
            ["intent": ["method": "session/set_mode", "params": [:]]],
            ["intent": ["method": "session/set_config_option", "params": ["configId": "c"]]],
            ["intent": ["method": "session/set_mode", "params": ["modeId": ["nested": true]]]],
            ["intent": ["method": "session/set_mode", "params": ["modeId": "x"], "other": 1]],
            ["intent": Self.mode, "connection": 1],
        ]
        for params in invalid { #expect(code(await rig.reserve(params)) == "transport.intent_invalid", "\(params)") }
        // An invalid intent leaves the gesture unused; drop it to ask without one.
        _ = rig.transport.gestures.consume()
        #expect(code(await rig.reserve(["intent": Self.mode], gesture: false)) == "transport.gesture_required")
        #expect(await rig.ticket(Self.mode) != nil)
    }

    @Test func aTicketPassesOnlyItsExactPick() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        // The pick it was reserved for passes, and the daemon never sees the ticket.
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "default"], ticket: await rig.ticket(Self.mode)) == nil)
        // A ticket for mode "default" on set_mode "bypassPermissions".
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "bypassPermissions"], ticket: await rig.ticket(Self.mode))
            == .gestureRequired)
        // An extra field: outside set_mode's known params, so the params rule refuses it (P1).
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "default", "force": true], ticket: await rig.ticket(Self.mode))
            == .intentInvalid)
        // "true" is not true.
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "thinking", "value": "true"], ticket: await rig.ticket(Self.effort))
            == .gestureRequired)
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "thinking", "value": true], ticket: await rig.ticket(Self.effort))
            == nil)
        // A session that is not the pane's.
        #expect(await rig.send("session/set_mode", ["sessionId": "s-foreign", "modeId": "default"], ticket: await rig.ticket(Self.mode))
            == .gestureRequired)
        #expect(await rig.server.wait { ($0.first?.frames.count ?? 0) >= 3 })
        #expect(rig.server.peers.first?.frames.contains { $0.contains("cmuxGesture") } == false)
    }

    @Test func onlySetModeAndSetConfigRedeemATicket() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        // A ticket on a permission allow, a prompt or a trust: refused (only a live gesture counts).
        // Their _meta may hold only acpmux, so the params rule refuses them first (P1).
        #expect(await rig.send("_acpmux/permission_group_respond", ["sessionId": "s", "groupId": "g", "revision": 1, "decision": "allow_once"],
                               ticket: await rig.ticket(Self.mode)) == .intentInvalid)
        #expect(await rig.send("session/prompt", ["sessionId": "s", "prompt": [Any]()], ticket: await rig.ticket(Self.mode)) == .intentInvalid)
        // The ticket was spent by the refused frame: its own pick no longer passes.
        let spent = await rig.ticket(Self.mode)
        _ = await rig.send("_acpmux/permission_group_respond", ["sessionId": "s", "groupId": "g", "revision": 2, "decision": "allow_once"], ticket: spent)
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "default"], ticket: spent) == .gestureRequired)
    }

    @Test func aTicketIsGoneAfterANewerReserveAReconnectOrTheSwitchsPrompt() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        // An old ticket after a new reserve for the same method.
        let old = await rig.ticket(Self.mode)
        let new = await rig.ticket(Self.mode)
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "default"], ticket: old) == .gestureRequired)
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "default"], ticket: new) == nil)
        // Two held config picks in one switch (model and effort) do not revoke each other; a newer
        // pick of the same config option does.
        let model = ["method": "session/set_config_option", "params": ["configId": "model", "value": "gpt-6"]] as [String: Any]
        let effortHigh = ["method": "session/set_config_option", "params": ["configId": "effort", "value": "high"]] as [String: Any]
        let effortLow = ["method": "session/set_config_option", "params": ["configId": "effort", "value": "low"]] as [String: Any]
        let modelTicket = await rig.ticket(model)
        let highTicket = await rig.ticket(effortHigh)
        let lowTicket = await rig.ticket(effortLow)
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "model", "value": "gpt-6"], ticket: modelTicket) == nil)
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "effort", "value": "high"], ticket: highTicket)
            == .gestureRequired, "revoked by the newer effort pick")
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "effort", "value": "low"], ticket: lowTicket) == nil)
        // A ticket from connection A on connection B (a reconnect).
        let fromA = await rig.ticket(Self.mode)
        try await rig.connect()
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "default"], ticket: fromA) == .gestureRequired)
        // The switch's prompt ends the switch: its unused tickets go.
        let unused = await rig.ticket(Self.mode)
        rig.transport.gestures.record()
        #expect(await rig.send("session/prompt", ["sessionId": "s", "prompt": [Any]()], ticket: nil) == nil)
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "default"], ticket: unused) == .gestureRequired)
        // A connection mismatch alone is refused (not only through the reconnect's clear).
        let gestures = AgentPaneUserGestures()
        gestures.record()
        let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": Self.mode]))
        let bound = try #require(gestures.reserve(connection: 1, intent: intent))
        #expect(!gestures.redeem(bound, connection: 2, method: "session/set_mode", params: ["sessionId": "s", "modeId": "default"]))
        // And it expires.
        var clock: TimeInterval = 0
        let timed = AgentPaneUserGestures(now: { clock })
        timed.record()
        let late = try #require(timed.reserve(connection: 1, intent: intent))
        clock += AgentPaneUserGestures.ticketLifetime + 1
        #expect(!timed.redeem(late, connection: 1, method: "session/set_mode", params: ["modeId": "default"]))
    }
}
