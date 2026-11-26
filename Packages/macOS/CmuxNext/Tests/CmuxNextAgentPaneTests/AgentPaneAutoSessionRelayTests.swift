import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Auto (plans/cmux-next/auto-mode/DESIGN.md) at the relay boundary (the page's frames into
/// ``AgentPaneTransport``, out to acpmux): the chat menu's Auto and Keep in Cloud, and the kept
/// changes' Show, Apply and Discard, reach acpmux only for the chat in the pane's scope, only in
/// the shapes the pane sends, and only on the person's gesture. The wake notice is the app's own
/// call on acpmux's socket, never the page's.
@Suite(.serialized)
@MainActor
struct AgentPaneAutoSessionRelayTests {
    static let set = "_acpmux/auto_session/set"
    static let leftover = "_acpmux/auto_session/leftover"

    static func frame(id: Int, method: String, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
    }

    @Test func autoAndTheKeptChangesGoOutInThePanesShapesForTheChatInScope() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let sent = { server.peers.first?.frames.filter { $0.contains("_acpmux/auto_session/") } ?? [] }

        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, method: Self.set, params: #"{"sessionId":"other","auto":true}"#)]) == .sessionNotInPane)
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 4, method: "_acpmux/auto_session/wake", params: "{}")]) != nil,
                "the wake notice is the app's, not the page's")
        #expect(sent().isEmpty, "a refused frame reached acpmux: \(sent())")

        // cmux#49717: a param the pane never sends is dropped, not refused; each goes without it.
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, method: Self.set, params: #"{"sessionId":"s","auto":true,"machine":"m"}"#)]) == nil,
                "the relay refused an auto set with a param the pane never sends")
        _ = await inbox.frame(containing: #""id":2"#)
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, method: Self.leftover, params: #"{"sessionId":"s","action":"apply","path":"/tmp/x"}"#)]) == nil,
                "the relay refused the kept changes with a path the pane never sends")
        _ = await inbox.frame(containing: #""id":3"#)
        let strippedParams = try sent().map { frame in
            let object = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
            return try #require(object?["params"] as? [String: Any]) as NSDictionary
        }
        #expect(strippedParams == [["sessionId": "s", "auto": true] as NSDictionary, ["sessionId": "s", "action": "apply"] as NSDictionary],
                "a dropped param reached acpmux: \(sent())")

        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 5, method: Self.set, params: #"{"sessionId":"s","auto":true,"keepInCloud":true}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":5"#)
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 6, method: Self.leftover, params: #"{"sessionId":"s","action":"discard"}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":6"#)
        let frames = Array(sent().dropFirst(2))
        #expect(frames.count == 2, "\(sent())")
        let params = try frames.map { frame in
            let object = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
            return try #require(object?["params"] as? [String: Any])
        }
        #expect(params.first?["auto"] as? Bool == true)
        #expect(params.first?["keepInCloud"] as? Bool == true)
        #expect(params.last?["action"] as? String == "discard")
    }

    /// Auto on sends the chat and its folder to the Cloud, and Apply or Discard changes the folder:
    /// each needs the person's gesture, the read of the kept changes included (one rule per method).
    @Test func bothNeedAGesture() {
        let options = AcpmuxPermissionOptions()
        #expect(AcpmuxPaneMethods.needsGesture(
            Self.frame(id: 1, method: Self.set, params: #"{"sessionId":"s","auto":true}"#), options: options))
        #expect(AcpmuxPaneMethods.needsGesture(
            Self.frame(id: 2, method: Self.leftover, params: #"{"sessionId":"s","action":"apply"}"#), options: options))
        #expect(AcpmuxPaneMethods.sessionScoped.isSuperset(of: [Self.set, Self.leftover]))
    }
}
