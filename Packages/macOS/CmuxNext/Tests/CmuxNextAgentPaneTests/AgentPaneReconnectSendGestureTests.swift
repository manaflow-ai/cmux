import Foundation
import Testing
import CmuxNextCompat
@testable import CmuxNextAgentPane

/// Leo, 2026-11-06, on a Mac at load 150-330 right after the nightly relaunched: "why is this still
/// happening yo". His own typed message came back "Not sent: it needs your own key press or click."
/// The page binds the person's Enter to its prompt at once (a send ticket, `bindSendGesture`), then
/// waits (the chat's open, the hand-off turn, a slow daemon) before the prompt goes. Under load the
/// pane's connection is replaced meanwhile (a stalled stream reconnects, `recoverStall`; acpmux
/// restarts; the page host's backlog closes it). The new connection dropped every ticket, and the
/// Enter's live gesture was already in the ticket, so the prompt reached the relay with nothing of
/// the person's left. A person's send ticket now outlives the connection it was taken on.
@Suite(.serialized)
@MainActor
struct AgentPaneReconnectSendGestureTests {
    typealias Slow = AgentPaneSlowStartPromptTests

    /// The connection a test's reconnect opened.
    @MainActor final class NextConnection { var id: Int? }

    static func sendIntent(_ promptId: String) throws -> AgentPaneGestureIntent {
        try #require(AgentPaneGestureIntent(gestureParams: [
            "intent": ["method": "session/prompt", "params": ["promptId": promptId]],
        ]))
    }

    static func prompt(id: Int, promptId: String, ticket: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"text","text":"what's going on here"}],"_meta":{"acpmux":{"promptId":"\#(promptId)"},"cmuxGesture":"\#(ticket)"}}}"#
    }

    /// Opens the pane's next connection to the same daemon, as the page does after a drop.
    static func reopen(_ pane: Slow.Pane) async throws -> Int {
        let again = try await pane.transport.open(AcpmuxConnection(url: pane.server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await pane.transport.send(connection: again, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        return again
    }

    /// A five-second main-thread stall between the Enter and its prompt, and the page reconnects
    /// meanwhile (its stall check gave up on the stream): the prompt still goes, once.
    @Test func aRealEnterSendsAcrossAReconnectDuringAFiveSecondStall() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.transport.gestures.record()
        let ticket = try #require(pane.transport.reserveGesture(Self.sendIntent("p-1")))
        pane.clock.now += 5
        pane.transport.close(connection: pane.id)
        let again = try await Self.reopen(pane)

        let sent = await pane.transport.send(connection: again, frames: [Self.prompt(id: 2, promptId: "p-1", ticket: ticket)])
        #expect(sent == nil, "the person's own Enter was refused after the pane reconnected")
        #expect(await pane.server.wait { peers in peers.dropFirst().contains { $0.frames.contains { $0.contains("session/prompt") } } })
        // The ticket is single use, on any connection.
        #expect(await pane.transport.send(connection: again, frames: [Self.prompt(id: 3, promptId: "p-1", ticket: ticket)]) == .gestureRequired)
    }

    /// acpmux restarts (or the nightly relaunched it) right after the Enter: the daemon closes the
    /// connection, the pane opens the next one, and the person's prompt goes there.
    @Test func aRealEnterSendsRightAfterTheDaemonRestarts() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }
        let closed = Mutex(false)
        pane.transport.deliver = { event, done in
            pane.inbox.deliver(event.frames)
            if event.closed != nil { closed.withLock { $0 = true } }
            done()
        }

        pane.transport.gestures.record()
        let ticket = try #require(pane.transport.reserveGesture(Self.sendIntent("p-1")))
        pane.server.pushThenClose([], to: 0)
        try #require(await pane.server.wait { _ in closed.withLock { $0 } }, "the daemon's close never reached the pane")
        let again = try await Self.reopen(pane)

        #expect(await pane.transport.send(connection: again, frames: [Self.prompt(id: 2, promptId: "p-1", ticket: ticket)]) == nil,
                "the person's own Enter was refused after acpmux restarted")
    }

    /// Only the person's send tickets carry over: an agent's prompt with no gesture is still refused on
    /// the new connection, and other picks (a mode) end with their connection as before.
    @Test func onlyThePersonsSendTicketsOutliveTheConnection() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.transport.close(connection: pane.id)
        let again = try await Self.reopen(pane)
        #expect(await pane.transport.send(connection: again, frames: [Slow.prompt(id: 2, promptId: "p-agent")]) == .gestureRequired)

        pane.transport.gestures.record()
        let mode = try #require(AgentPaneGestureIntent(gestureParams: [
            "intent": ["method": "session/set_mode", "params": ["modeId": "plan"]],
        ]))
        let modeTicket = try #require(pane.transport.reserveGesture(mode))
        pane.transport.close(connection: again)
        let third = try await Self.reopen(pane)
        let setMode = #"{"jsonrpc":"2.0","id":3,"method":"session/set_mode","params":{"sessionId":"s-new","modeId":"plan","_meta":{"cmuxGesture":"\#(modeTicket)"}}}"#
        #expect(await pane.transport.send(connection: third, frames: [setMode]) == .gestureRequired)
    }

    /// The review of #36961: the pane reconnects while the prompt's frame is read off the main
    /// actor. That frame goes nowhere, and it must not spend the ticket the person's Enter left, so
    /// the page's prompt on the next connection still goes.
    @Test func aFrameLeftStaleByAReconnectSpendsNoSendTicket() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.transport.gestures.record()
        let ticket = try #require(pane.transport.reserveGesture(Self.sendIntent("p-1")))
        let next = NextConnection()
        pane.transport.afterAnalyze = { [transport = pane.transport, url = pane.server.url] in
            transport.afterAnalyze = nil
            next.id = try? await transport.open(AcpmuxConnection(url: url, dashboardToken: "t", localAppToken: nil))
        }
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 2, promptId: "p-1", ticket: ticket)]) == .staleConnection)
        let again = try #require(next.id, "the pane did not reconnect")
        #expect(await pane.transport.send(connection: again, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)

        #expect(await pane.transport.send(connection: again, frames: [Self.prompt(id: 3, promptId: "p-1", ticket: ticket)]) == nil,
                "the stale frame spent the person's send ticket")
    }
}
