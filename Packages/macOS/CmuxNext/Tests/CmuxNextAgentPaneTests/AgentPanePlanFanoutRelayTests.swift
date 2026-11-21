import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Run on N agents (cmux#38503): the composer's prompt goes through the relay to acpmux as
/// `_acpmux/plan/fanout`, on the person's gesture and a ticket bound to that prompt and those
/// agents, and the runs card's Keep with `removeOthers` goes with no gesture (it starts nothing).
@Suite(.serialized)
@MainActor
struct AgentPanePlanFanoutRelayTests {
    typealias Slow = AgentPaneSlowStartPromptTests

    static let variants: [[String: Any]] = [["harness": "claude", "model": "claude-opus-5-5"], ["harness": "codex"]]

    static func intent(prompt: String, variants: [[String: Any]]) throws -> AgentPaneGestureIntent {
        let params: [String: Any] = ["sessionId": "s-new", "prompt": prompt, "variants": variants]
        return try #require(AgentPaneGestureIntent(gestureParams: [
            "intent": ["method": "_acpmux/plan/fanout", "params": params] as [String: Any],
        ]))
    }

    static func fanout(id: Int, prompt: String, variants: [[String: Any]], ticket: String?) throws -> String {
        var params: [String: Any] = ["sessionId": "s-new", "prompt": prompt, "variants": variants]
        if let ticket { params["_meta"] = [AcpmuxPaneMethods.gestureTicketKey: ticket] }
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "_acpmux/plan/fanout", "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    static func paneWithChat() async throws -> Slow.Pane {
        let pane = try await Slow.pane()
        #expect(await Slow.start(pane, id: 1) == nil)
        return pane
    }

    @Test func aRunGoesToAcpmuxOnItsTicketWithoutTheTicket() async throws {
        let pane = try await Self.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.transport.gestures.record(click: true)
        let ticket = try #require(pane.transport.reserveGesture(Self.intent(prompt: "Add a NOTICE", variants: Self.variants)))
        let frame = try Self.fanout(id: 2, prompt: "Add a NOTICE", variants: Self.variants, ticket: ticket)
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) == nil)
        _ = await pane.inbox.frame(containing: #""id":2"#)
        let sent = pane.server.peers.first?.frames.first { $0.contains("_acpmux/plan/fanout") }
        #expect(sent != nil, "the run never reached acpmux")
        #expect(sent?.contains(AcpmuxPaneMethods.gestureTicketKey) == false, "the ticket reached acpmux")
    }

    @Test func aTicketForTwoAgentsNeverStartsThree() async throws {
        let pane = try await Self.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.transport.gestures.record(click: true)
        let ticket = try #require(pane.transport.reserveGesture(Self.intent(prompt: "Add a NOTICE", variants: Self.variants)))
        let three = Self.variants + [["harness": "claude", "model": "claude-sonnet-5-5"]]
        let frame = try Self.fanout(id: 2, prompt: "Add a NOTICE", variants: three, ticket: ticket)
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) != nil)
        let other = try Self.fanout(id: 3, prompt: "Delete the repo", variants: Self.variants, ticket: ticket)
        #expect(await pane.transport.send(connection: pane.id, frames: [other]) != nil)
        #expect(pane.server.peers.first?.frames.contains { $0.contains("_acpmux/plan/fanout") } == false)
    }

    /// A run's model reaches a harness's argv (`${model}`): one id, as a start's model is, even on
    /// the person's own ticket for it (cmux#38503 review: `m$(touch /tmp/pwn)`).
    @Test(arguments: ["m$(touch /tmp/pwn)", "m`id`", "m;id", "claude opus", "m\nid", "--yolo"])
    func aRunWhoseModelIsNotOneIdNeverReachesAcpmux(model: String) async throws {
        let pane = try await Self.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        let variants: [[String: Any]] = [["harness": "claude", "model": model], ["harness": "codex"]]
        pane.transport.gestures.record(click: true)
        // Refused when the ticket is made or when the run is sent: either way it never goes.
        let ticket = pane.transport.reserveGesture(try Self.intent(prompt: "Add a NOTICE", variants: variants))
        let frame = try Self.fanout(id: 2, prompt: "Add a NOTICE", variants: variants, ticket: ticket ?? "t")
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) != nil)
        #expect(pane.server.peers.first?.frames.contains { $0.contains("_acpmux/plan/fanout") } == false)
    }

    @Test func aRunWithNoGestureOfThePersonsIsRefused() async throws {
        let pane = try await Self.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        let frame = try Self.fanout(id: 2, prompt: "Add a NOTICE", variants: Self.variants, ticket: nil)
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) == .gestureRequired)
    }

    @Test func keepWithRemoveOthersGoesWithNoGesture() async throws {
        let pane = try await Self.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        let keep = #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/plan/keep","params":{"sessionId":"s-new","buildId":"b","keep":"c","removeOthers":true}}"#
        #expect(await pane.transport.send(connection: pane.id, frames: [keep]) == nil)
        _ = await pane.inbox.frame(containing: #""id":2"#)
        #expect(pane.server.peers.first?.frames.contains { $0.contains("removeOthers") } == true)
    }
}
