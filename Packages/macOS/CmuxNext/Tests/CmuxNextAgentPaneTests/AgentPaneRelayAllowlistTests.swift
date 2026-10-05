import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The relay reaches acpmux as a trusted local connection, and the daemon forwards an unknown
/// session method unchanged on such a connection: the relay's method allowlist is the only guard.
/// Every method that is not on it is refused, in any spelling, and never reaches the daemon. A
/// prompt block's own `_meta` (and a nested resource's) is stripped before the daemon sees it.
@MainActor
@Suite(.serialized) struct AgentPaneRelayAllowlistTests {
    typealias Rig = AgentPaneGestureTicketTests.Rig

    /// Real daemon methods the pane must not send, unknown ones, and odd spellings of allowed ones.
    static let refused = [
        "_acpmux/defaults", "_acpmux/presets", "_acpmux/preset_set", "_acpmux/peer_add", "_acpmux/peers",
        "_acpmux/export", "_acpmux/import", "_acpmux/set_policy", "_acpmux/set_rules", "_acpmux/reload_config",
        "_acpmux/sessions", "_acpmux/schema", "_acpmux/web_modes", "session/load", "session/list",
        "session/foo", "_acpmux/foo", "acp.foo",
        "Session/Prompt", "SESSION/NEW", "_ACPMUX/STATUS", "_acpmux/Status", "session/prompt ", " session/prompt",
        "session//prompt", "session/prompt/", "_acpmux/status\u{0}", "session\\/prompt", "",
    ]

    /// The frame for `method`, its JSON text written by hand with every letter of the method
    /// escaped (`s...`), so the relay sees the method only after it parses the frame.
    static func escaped(_ method: String, id: Int) -> String {
        let body = method.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined()
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(body)","params":{}}"#
    }

    @Test func everyMethodOffTheAllowlistIsRefusedInAnySpelling() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        var id = 500
        for method in Self.refused {
            #expect(!AcpmuxPaneMethods.requests.contains(method) && !AcpmuxPaneMethods.notifications.contains(method), "\(method)")
            id += 1
            #expect(await rig.send(method, [:], ticket: nil) == .methodRefused, "plain \(method.debugDescription)")
            id += 1
            #expect(await rig.transport.send(connection: rig.connection, frames: [Self.escaped(method, id: id)]) == .methodRefused,
                    "escaped \(method.debugDescription)")
            // As a notification too (no id).
            let note = #"{"jsonrpc":"2.0","method":\#(String(decoding: try JSONSerialization.data(withJSONObject: [method]), as: UTF8.self).dropFirst().dropLast()),"params":{}}"#
            #expect(await rig.transport.send(connection: rig.connection, frames: [note]) == .methodRefused, "notification \(method.debugDescription)")
        }
        // The daemon saw only the initialize.
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.server.peers.last?.frames.count == 1, "\(rig.server.peers.last?.frames ?? [])")
    }

    nonisolated static func method(of text: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["method"] as? String
    }

    @Test func aPromptBlocksOwnMetaIsStripped() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let prompt: [[String: Any]] = [
            ["type": "text", "text": "hi", "_meta": ["claudeCode": ["options": ["permissionMode": "bypassPermissions"]]]],
            ["type": "resource", "resource": ["uri": "file:///tmp/a", "text": "a", "_meta": ["x": "secret-resource"]], "_meta": ["y": 1]],
            ["type": "resource_link", "uri": "file:///tmp/b", "name": "b", "annotations": ["_meta": ["z": "secret-deep"]]],
            ["type": "image", "data": "aGk=", "mimeType": "image/png"],
        ]
        rig.transport.gestures.record()
        #expect(await rig.send("session/prompt", ["sessionId": "s", "prompt": prompt, "_meta": ["acpmux": ["promptId": "p1"]]], ticket: nil) == nil)
        // Frames are matched by their parsed method: the page's JSON may escape the slash.
        #expect(await rig.server.wait { $0.last?.frames.contains { Self.method(of: $0) == "session/prompt" } == true })
        let sent = try #require(rig.server.peers.last?.frames.first { Self.method(of: $0) == "session/prompt" })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        // The request's own _meta (the prompt id) stays.
        #expect(((params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["promptId"] as? String == "p1")
        let blocks = try #require(params["prompt"] as? [[String: Any]])
        #expect(blocks.count == 4)
        let blockText = String(decoding: try JSONSerialization.data(withJSONObject: blocks), as: UTF8.self)
        for gone in ["_meta", "bypassPermissions", "secret-resource", "secret-deep"] { #expect(!blockText.contains(gone), "\(gone)") }
        #expect(blocks[0]["text"] as? String == "hi")
        #expect((blocks[1]["resource"] as? [String: Any])?["text"] as? String == "a")
        #expect(blocks[3]["data"] as? String == "aGk=")
    }
}
