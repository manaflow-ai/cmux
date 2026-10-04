import Foundation
import Testing
@testable import CmuxNextAgentPane

/// (a), ad349: a frame that GRANTS needs a fresh user gesture, consumed by the host (one gesture
/// per grant). A deny or revoke needs none. Without one: transport.gesture_required, a JSON-RPC
/// error, and the socket stays open.
@MainActor
@Suite(.serialized) struct AgentPaneGestureTests {
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#
    nonisolated static let pending = #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p1","request":{"options":[{"optionId":"no","name":"Deny","kind":"reject_once"},{"optionId":"yes","name":"Allow","kind":"allow_once"}]}}}"#

    private func frame(_ id: Int, _ method: String, _ params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func whichFramesGrant() {
        let options = AcpmuxPermissionOptions()
        options.observe(Self.pending)
        let grants: [(String, Bool)] = [
            (frame(1, "session/prompt", #"{"sessionId":"s","prompt":[]}"#), true),
            (frame(1, "session/set_mode", #"{"sessionId":"s","modeId":"default"}"#), true),
            (frame(1, "session/set_config_option", #"{"sessionId":"s","configId":"c","value":"v"}"#), true),
            (frame(1, "acp.trust.set", #"{"cwd":"/x","level":"trusted"}"#), true),
            (frame(1, "acp.trust.set", #"{"cwd":"/x","level":"untrusted"}"#), false),
            (frame(1, "acp.trust.set", #"{"cwd":"/x","level":"unknown"}"#), false),
            (frame(1, "_acpmux/permission_respond", #"{"sessionId":"s","permissionId":"p1","optionId":"yes"}"#), true),
            (frame(1, "_acpmux/permission_respond", #"{"sessionId":"s","permissionId":"p1","optionId":"no"}"#), false),
            // An option the host never saw counts as an allow.
            (frame(1, "_acpmux/permission_respond", #"{"sessionId":"s","permissionId":"p9","optionId":"no"}"#), true),
            (frame(1, "_acpmux/permission_group_respond", #"{"sessionId":"s","groupId":"g","revision":1,"decision":"allow_once"}"#), true),
            (frame(1, "_acpmux/permission_group_respond", #"{"sessionId":"s","groupId":"g","revision":1,"decision":"allow_chat"}"#), true),
            (frame(1, "_acpmux/permission_group_respond", #"{"sessionId":"s","groupId":"g","revision":1,"decision":"deny"}"#), false),
            (frame(1, "_acpmux/permission_chat_revoke", #"{"sessionId":"s"}"#), false),
            (frame(1, "_acpmux/watch", #"{"enabled":true}"#), false),
            (frame(1, "session/new", #"{"mcpServers":[]}"#), false),
            // An escaped method name is still the method.
            (#"{"jsonrpc":"2.0","id":1,"method":"session\/prompt","params":{"sessionId":"s","prompt":[]}}"#, true),
        ]
        for (text, expected) in grants {
            #expect(AcpmuxPaneMethods.needsGesture(text, options: options) == expected, "\(text)")
        }
    }

    @Test func aGestureIsUsedOnceAndExpires() {
        var clock: TimeInterval = 100
        let gestures = AgentPaneUserGestures(now: { clock })
        #expect(!gestures.consume())
        gestures.record()
        #expect(gestures.consume())
        #expect(!gestures.consume(), "the record is cleared when used")
        gestures.record()
        clock += AgentPaneUserGestures.lifetime + 1
        #expect(!gestures.consume(), "an old gesture is gone")
    }

    @Test func anAllowWithoutAGestureIsRefusedAndOneGesturePassesExactlyOneGrant() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        server.push(Self.pending, to: 0)
        #expect(await eventually { events.flatMap(\.frames).contains { $0.contains("permission_pending") } })

        // An injected allow, with no gesture: refused, answered, never sent; the socket stays open.
        let allow = frame(7, "_acpmux/permission_respond", #"{"sessionId":"s","permissionId":"p1","optionId":"yes"}"#)
        #expect(await transport.send(connection: id, frames: [allow]) == .gestureRequired)
        #expect(await eventually { events.flatMap(\.frames).contains { $0.contains(#""id":7"#) && $0.contains("transport.gesture_required") } })
        #expect(transport.connection == id)

        // A deny needs none.
        let deny = frame(8, "_acpmux/permission_respond", #"{"sessionId":"s","permissionId":"p1","optionId":"no"}"#)
        #expect(await transport.send(connection: id, frames: [deny]) == nil)

        // One gesture: exactly one grant passes.
        transport.gestures.record()
        let first = frame(9, "_acpmux/permission_group_respond", #"{"sessionId":"s","groupId":"g","revision":1,"decision":"allow_once"}"#)
        let second = frame(10, "_acpmux/permission_group_respond", #"{"sessionId":"s","groupId":"g","revision":2,"decision":"allow_chat"}"#)
        #expect(await transport.send(connection: id, frames: [first]) == nil)
        #expect(await transport.send(connection: id, frames: [second]) == .gestureRequired)

        #expect(await server.wait { $0.first?.frames.count == 3 })
        let sent = server.peers.first?.frames ?? []
        #expect(sent.contains { $0.contains(#""id":8"#) } && sent.contains { $0.contains(#""id":9"#) })
        #expect(!sent.contains { $0.contains(#""id":7"#) || $0.contains(#""id":10"#) })
    }
}
