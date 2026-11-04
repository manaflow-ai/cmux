import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Fork Conversation (the palette's step, the chat's right-click menu, its shortcut) forks a
/// working chat as it is now: the page sends `acp.session.fork {sessionId, live: true}`
/// (`direct.ts` `fork("live")`), which acpmux serves (`server/fork_through.rs`). The host's
/// params rule let only `throughSeq` through, so every fork of a working chat was refused with
/// `transport.intent_invalid` and no fork opened (NIGHTLY 2026-10-29, "it actually failed").
@Suite
struct AgentPaneForkRelayTests {
    static func object(_ params: String) -> [String: Any]? {
        let frame = #"{"jsonrpc":"2.0","id":7,"method":"acp.session.fork","params":\#(params)}"#
        return (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
    }

    @Test(arguments: [
        #"{"sessionId":"s","live":true}"#,
        #"{"sessionId":"s","throughSeq":12}"#,
    ])
    func thePagesForkFramesPassTheParamsRule(_ params: String) {
        #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.object(params), modeFields: []), "\(params)")
    }

    @Test(arguments: [
        #"{"sessionId":"s","live":true,"_meta":{"acpmux":{"via":"web"}}}"#,
        #"{"sessionId":"s","live":true,"cwd":"/"}"#,
    ])
    func aForkCarriesNothingElse(_ params: String) {
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.object(params), modeFields: []), "\(params)")
    }

    static func frame(id: Int, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"acp.session.fork","params":\#(params)}"#
    }

    /// A fork of a chat outside the pane's scope waits for the click's scope credit, as an attach the
    /// person makes (``AcpmuxPaneMethods/sourceScoped``, `AgentPaneTransport+Frames.swift`
    /// `consumeScope`). `live` names no other source and needs the click too; one click brings one
    /// fork. The pane's own chat forks with no click. The Rust copy of this rule is
    /// cmux-agent-pane-policy tests/cases/check.json ("live fork from outside the scope uses scope
    /// credit"); this test runs the rule in the host that serves the pane.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func aForkFromOutsideTheScopeGoesOutOnlyWithTheClick() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("acp.session.fork", with: #"{"sessionId":"f1"}"#)
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let sent = { server.peers.first?.frames.filter { $0.contains("acp.session.fork") } ?? [] }
        func params(_ frame: String) throws -> NSDictionary {
            let object = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
            return try #require(object?["params"] as? [String: Any]) as NSDictionary
        }

        // No click: a chat outside the scope, with `live` and through a turn.
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, params: #"{"sessionId":"other","live":true}"#)]) == .gestureRequired,
                "a live fork of a chat outside the pane's scope, with no click")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, params: #"{"sessionId":"other","throughSeq":3}"#)]) == .gestureRequired,
                "a fork through a turn of a chat outside the pane's scope, with no click")
        #expect(sent().isEmpty, "a refused fork reached acpmux: \(sent())")

        // The pane's own chat forks with no click.
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, params: #"{"sessionId":"s","live":true}"#)]) == nil,
                "the relay refused a live fork of the pane's own chat")
        _ = await inbox.frame(containing: #""id":3"#)
        #expect(try sent().map(params) == [["sessionId": "s", "live": true] as NSDictionary])

        // A click brings one fork of a chat outside the scope in.
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 4, params: #"{"sessionId":"other","live":true}"#)]) == nil,
                "the relay refused a live fork the person clicked for")
        _ = await inbox.frame(containing: #""id":4"#)
        #expect(try sent().dropFirst().map(params) == [["sessionId": "other", "live": true] as NSDictionary])

        // The click's credit is spent: the next fork outside the scope needs its own click.
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 5, params: #"{"sessionId":"other","throughSeq":3}"#)]) == .gestureRequired)
        #expect(sent().count == 2, "\(sent())")
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 6, params: #"{"sessionId":"other","throughSeq":3}"#)]) == nil,
                "the relay refused a fork through a turn the person clicked for")
        _ = await inbox.frame(containing: #""id":6"#)
        #expect(try sent().dropFirst(2).map(params) == [["sessionId": "other", "throughSeq": 3] as NSDictionary])
    }
}
