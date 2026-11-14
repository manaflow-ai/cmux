import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite(.serialized)
@MainActor
struct AgentPaneFixFromLinkGestureTests {
    final class Clock { var now: TimeInterval = 100 }
    @Test func preparationNeedsNoGestureButLaunchRequiresItsExactTicketOnce() async throws {
        let pane = try await AgentPaneSlowStartPromptTests.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }
        let params: [String: Any] = ["url": "https://github.com/acme/widget/issues/12"]
        func frame(_ method: String, _ id: Int, _ ticket: String? = nil) throws -> String {
            var request = params
            if let ticket { request["_meta"] = ["cmuxGesture": ticket] }
            return String(decoding: try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": method, "params": request,
            ]), as: UTF8.self)
        }
        #expect(await pane.transport.send(connection: pane.id, frames: [try frame("chat.fix_from_link.prepare", 1)]) == nil)
        #expect(await pane.transport.send(connection: pane.id, frames: [try frame("chat.fix_from_link", 2)]) == .gestureRequired)
        let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "chat.fix_from_link", "params": params]]))
        pane.transport.gestures.record()
        let ticket = try #require(pane.transport.reserveGesture(intent))
        // The person's Trust click can be spent independently while the original fix stays held.
        pane.clock.now += 90
        pane.transport.gestures.record()
        #expect(pane.transport.gestures.consume())
        #expect(await pane.transport.send(connection: pane.id, frames: [try frame("chat.fix_from_link", 3, ticket)]) == nil)
        #expect(await pane.transport.send(connection: pane.id, frames: [try frame("chat.fix_from_link", 4, ticket)]) == .gestureRequired)
    }

    @Test func launchSelectionsCannotBeSubstitutedAndTicketsExpire() throws {
        let clock = Clock()
        let gestures = AgentPaneUserGestures(now: { clock.now })
        let params: [String: Any] = ["url": "https://github.com/acme/widget/issues/12", "cwd": "/repo/subdir", "harness": "codex", "model": "gpt-6-astra"]
        let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "chat.fix_from_link", "params": params]]))
        for key in params.keys {
            gestures.record()
            let ticket = try #require(gestures.reserve(connection: 1, intent: intent))
            var altered = params
            altered[key] = "different"
            #expect(!gestures.redeem(ticket, connection: 1, method: "chat.fix_from_link", params: altered))
            #expect(!gestures.redeem(ticket, connection: 1, method: "chat.fix_from_link", params: params))
        }
        gestures.record()
        let ticket = try #require(gestures.reserve(connection: 1, intent: intent))
        clock.now += AgentPaneUserGestures.heldPromptLifetime + 1
        #expect(!gestures.redeem(ticket, connection: 1, method: "chat.fix_from_link", params: params))
    }

    @Test func onlyTheDaemonCreatedSessionEntersScope() {
        let sessions = AcpmuxPaneSessions()
        sessions.sent(method: "chat.fix_from_link.prepare", id: "1")
        sessions.observe(["id": 1, "result": ["sessionId": "not-created"]])
        #expect(!sessions.contains("not-created"))
        sessions.sent(method: "chat.fix_from_link", id: "2")
        sessions.observe(["id": 2, "result": ["sessionId": "created"]])
        #expect(sessions.contains("created"))
        sessions.observe(["id": 3, "result": ["sessionId": "unrelated"]])
        #expect(!sessions.contains("unrelated"))
    }
}
