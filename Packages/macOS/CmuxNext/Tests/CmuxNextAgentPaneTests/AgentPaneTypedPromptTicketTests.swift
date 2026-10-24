import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A message the person types into the composer is always theirs, sent behind a running turn or
/// as a steer (Leo, 2026-10-21: a typed steer came back "Not sent: it needs your own key press or
/// click" under the steer before it). The relay counted one gesture at a time and checked each
/// frame only when it got to it: two Enters before the first frame was checked left the second
/// with nothing. Each send now binds its Enter to its own promptId at once (direct.ts
/// `reservePromptGesture`), and that ticket waits for its frame however late it comes. A ticket is
/// that prompt's alone: no other prompt, and no second use.
@Suite(.serialized)
@MainActor
struct AgentPaneTypedPromptTicketTests {
    /// A chat the page started by itself (no gesture of the person's): the pane's `s-new`.
    static func chat() async throws -> AgentPaneSlowStartPromptTests.Pane {
        let pane = try await AgentPaneSlowStartPromptTests.pane()
        #expect(await AgentPaneSlowStartPromptTests.start(pane, id: 1) == nil)
        #expect(!pane.transport.gestures.isAvailable)
        return pane
    }

    static func intent(_ promptId: String) throws -> AgentPaneGestureIntent {
        let request: [String: Any] = ["method": "session/prompt", "params": ["promptId": promptId] as [String: Any]]
        return try #require(AgentPaneGestureIntent(gestureParams: ["intent": request]))
    }

    /// The person's Enter on the composer, and the page's reserve for that send's promptId.
    static func enter(_ pane: AgentPaneSlowStartPromptTests.Pane, promptId: String) throws -> String {
        pane.transport.gestures.record()
        return try #require(pane.transport.reserveGesture(intent(promptId)), "the Enter gave its prompt no ticket")
    }

    static func prompt(id: Int, promptId: String, ticket: String?, steer: Bool = false) -> String {
        let acpmux = #"{"promptId":"\#(promptId)"\#(steer ? #","steer":true"# : "")}"#
        let gesture = ticket.map { #","cmuxGesture":"\#($0)""# } ?? ""
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"text","text":"Keep the old flag"}],"_meta":{"acpmux":\#(acpmux)\#(gesture)}}}"#
    }

    static func send(_ pane: AgentPaneSlowStartPromptTests.Pane, _ frame: String) async -> AgentPaneTransportError? {
        await pane.transport.send(connection: pane.id, frames: [frame])
    }

    @Test func twoPromptsTypedBehindARunningTurnBothGo() async throws {
        let pane = try await Self.chat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        // Two messages typed while a turn runs, each with its own Enter, before the relay checks
        // either: the second Enter must not take the first one's ticket.
        let first = try Self.enter(pane, promptId: "p-1")
        let second = try Self.enter(pane, promptId: "p-2")
        // The relay gets to them long after the person's keys (a busy pane, a turn that runs on).
        pane.clock.now += 45
        #expect(!pane.transport.gestures.isAvailable, "the test needs the live gesture to have expired")

        #expect(await Self.send(pane, Self.prompt(id: 2, promptId: "p-1", ticket: first)) == nil,
                "the first typed prompt lost its Enter to the second one's")
        // The first prompt going out does not end the second one's ticket.
        #expect(await Self.send(pane, Self.prompt(id: 3, promptId: "p-2", ticket: second)) == nil,
                "the second typed prompt was refused once the first went out")
        _ = await pane.inbox.frame(containing: #""id":3"#)
        let prompts = pane.server.peers.first?.frames.filter { $0.contains("session/prompt") } ?? []
        #expect(prompts.count == 2)
    }

    @Test func aSteerTypedRightAfterAQueuedPromptGoes() async throws {
        let pane = try await Self.chat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        // A prompt queued behind the turn, then a steer typed at once; the steer's frame is checked first.
        let queued = try Self.enter(pane, promptId: "p-queued")
        let steer = try Self.enter(pane, promptId: "p-steer")
        #expect(await Self.send(pane, Self.prompt(id: 2, promptId: "p-steer", ticket: steer, steer: true)) == nil,
                "the typed steer came back Not sent")
        pane.clock.now += 45
        #expect(await Self.send(pane, Self.prompt(id: 3, promptId: "p-queued", ticket: queued)) == nil,
                "the queued prompt lost its Enter to the steer typed after it")
    }

    /// The guarantee stays: a ticket sends only the prompt it was reserved for, once, and a prompt
    /// with no gesture of the person's behind it (a script, an agent) is refused.
    @Test func aPromptTicketSendsOnlyItsOwnPromptOnce() async throws {
        let pane = try await Self.chat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        let mine = try Self.enter(pane, promptId: "p-mine")
        // Another prompt (other content, another promptId) cannot ride on it; the ticket is spent.
        #expect(await Self.send(pane, Self.prompt(id: 2, promptId: "p-other", ticket: mine)) == .gestureRequired)
        #expect(await Self.send(pane, Self.prompt(id: 3, promptId: "p-mine", ticket: mine)) == .gestureRequired)

        let again = try Self.enter(pane, promptId: "p-again")
        #expect(await Self.send(pane, Self.prompt(id: 4, promptId: "p-again", ticket: again)) == nil)
        // Replayed after it was used: refused.
        #expect(await Self.send(pane, Self.prompt(id: 5, promptId: "p-again", ticket: again)) == .gestureRequired)
        // No gesture, no ticket: a prompt nobody typed does not go.
        #expect(await Self.send(pane, Self.prompt(id: 6, promptId: "p-script", ticket: nil)) == .gestureRequired)
        // A reserve with no gesture of the person's gets no ticket.
        #expect(pane.transport.reserveGesture(try Self.intent("p-script")) == nil)
    }

    /// However many prompts the person types before the relay gets to them, each keeps its Enter.
    @Test func manyPromptsTypedFastAllGo() async throws {
        let pane = try await Self.chat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        let count = AgentPaneUserGestures.promptTicketsKept * 2
        var tickets: [String] = []
        for index in 0..<count { tickets.append(try Self.enter(pane, promptId: "p-\(index)")) }
        pane.clock.now += 45
        for index in 0..<count {
            #expect(await Self.send(pane, Self.prompt(id: index + 2, promptId: "p-\(index)", ticket: tickets[index])) == nil,
                    "typed prompt \(index) lost its Enter")
        }
    }

    /// Tickets do not pile up: past a few, a ticket left waiting longer than a live gesture goes, so a
    /// page that reserves one on every key press cannot send them all once the person has gone.
    @Test func aConnectionKeepsOnlyAFewWaitingPromptTickets() async throws {
        let pane = try await Self.chat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        let kept = AgentPaneUserGestures.promptTicketsKept
        var tickets: [String] = []
        for index in 0..<kept { tickets.append(try Self.enter(pane, promptId: "p-\(index)")) }
        pane.clock.now += AgentPaneUserGestures.lifetime + 1
        tickets.append(try Self.enter(pane, promptId: "p-\(kept)"))
        #expect(pane.transport.gestures.ticketCount == kept)
        // The oldest went; the newest still goes.
        #expect(await Self.send(pane, Self.prompt(id: 2, promptId: "p-0", ticket: tickets[0])) == .gestureRequired)
        #expect(await Self.send(pane, Self.prompt(id: 3, promptId: "p-\(kept)", ticket: tickets[kept])) == nil)
    }

    /// A page that reserves on every key press and never sends holds no more than a bounded few.
    @Test func freshPromptTicketsAreBoundedToo() async throws {
        let pane = try await Self.chat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        let max = AgentPaneUserGestures.promptTicketsMax
        for index in 0...max { _ = try Self.enter(pane, promptId: "p-\(index)") }
        #expect(pane.transport.gestures.ticketCount == max)
    }
}
