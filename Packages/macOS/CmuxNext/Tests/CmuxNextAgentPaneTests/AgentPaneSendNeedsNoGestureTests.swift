import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo, 2026-11-17, on a chat message marked "Not sent: it needs your own key press or click": "go
/// remove this". Every way a message is sent goes out with no key press or click of the person's
/// behind it, and nothing comes back "Not sent": the composer and its Retry, Approve, `/btw`,
/// `/side`, Fix from a link, a review verdict, an agent or computer use driving the pane (posted
/// input records no gesture), a prompt carrying a spent or forged ticket, and a new chat on another
/// machine (the remote wire the iOS app's and other Macs' chats use). MCP and the CLI reach acpmux
/// without the pane; the frame rules they share are checked against this table in Rust
/// (cmux-agent-pane-policy tests/swift.rs `no_send_needs_a_gesture`).
@Suite(.serialized)
@MainActor
struct AgentPaneSendNeedsNoGestureTests {
    typealias Slow = AgentPaneSlowStartPromptTests

    /// Every page frame that sends a message or runs a turn.
    static let sendMethods = [
        "session/prompt", "chat.fix_from_link", "_acpmux/queue_approve", "_acpmux/review_verdict", "_acpmux/btw",
        "_acpmux/side_chat", "_acpmux/agent_pair_resume", "_acpmux/agent_hold", "_acpmux/app_reply",
        "_acpmux/race/start", "_acpmux/run_elsewhere/start",
    ]

    @Test func noSendMethodNeedsAGesture() {
        for method in Self.sendMethods {
            #expect(AcpmuxPaneMethods.gestureRules[method] == nil, "\(method) still needs a gesture")
            let frame = #"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{"sessionId":"s","prompt":[]}}"#
            #expect(!AcpmuxPaneMethods.needsGesture(frame, options: AcpmuxPermissionOptions()), "\(method)")
        }
    }

    /// The composer's Send and its Retry, with no key press or click recorded (computer use, a
    /// script, an agent): each goes to acpmux.
    @Test func aComposerSendAndItsRetryGoWithNoGesture() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        #expect(!pane.transport.gestures.isAvailable)
        #expect(await pane.transport.send(connection: pane.id, frames: [Slow.prompt(id: 2, promptId: "p-1")]) == nil)
        _ = await pane.inbox.frame(containing: #""id":2"#)
        // Retry sends the same prompt again.
        #expect(await pane.transport.send(connection: pane.id, frames: [Slow.prompt(id: 3, promptId: "p-1")]) == nil)
        _ = await pane.inbox.frame(containing: #""id":3"#)
        #expect(pane.server.peers.first?.frames.filter { $0.contains("session/prompt") }.count == 2)
    }

    /// A prompt whose ticket was spent, expired or never issued (an agent replaying the page's frame)
    /// still goes: a ticket only carries a pick, and a send needs none.
    @Test func aPromptWithASpentOrForgedTicketGoes() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        let frame = #"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"text","text":"hi"}],"_meta":{"acpmux":{"promptId":"p-1"},"cmuxGesture":"\#(UUID().uuidString)"}}}"#
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) == nil)
        _ = await pane.inbox.frame(containing: #""id":2"#)
    }

    /// A send's ticket (a held prompt, a prompt with attachments) comes with no gesture.
    @Test func aSendTicketNeedsNoGesture() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        for method in ["session/prompt", "cloud.startChat"] {
            let params: [String: Any] = method == "session/prompt" ? ["promptId": "p-1"] : ["key": UUID().uuidString]
            let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": method, "params": params]]))
            #expect(pane.transport.reserveGesture(intent) != nil, "\(method) got no ticket without a gesture")
        }
        // A grant that is not a send still needs the person.
        let mode = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/set_mode", "params": ["modeId": "plan"]]]))
        #expect(pane.transport.reserveGesture(mode) == nil)
    }

    /// A new chat on another machine (the remote wire) starts with no gesture: its first send is the
    /// person's message, whoever pressed Send.
    @Test func aNewChatOnAnotherMachineStartsWithNoGesture() async throws {
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let wire = AgentPaneRelayedAllowTests.RemoteWire()
        let id = try await transport.open(.remote(AgentPaneRemoteRoute(machine: "host") { wire }))
        defer { transport.close(connection: id) }
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        _ = await inbox.frame(containing: #""id":0"#)

        let start = #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/srv/project","mcpServers":[]}}"#
        #expect(await transport.send(connection: id, frames: [start]) == nil, "a new chat on another machine was refused")
        _ = await inbox.frame(containing: #""id":1"#)
    }
}
