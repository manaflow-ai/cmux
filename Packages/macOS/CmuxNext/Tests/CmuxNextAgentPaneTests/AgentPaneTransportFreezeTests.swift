import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A frozen chat with no turn running closes its acpmux connection, so acpmux holds no
/// socket for it. The thaw hands the page every frame that arrived before the close, then the close, in
/// one call; the page's one reconnect opens a new connection, on which acpmux replays the chat.
@Suite(.serialized)
@MainActor
struct AgentPaneTransportFreezeTests {
    /// What the page got, one entry per bridge call.
    @MainActor final class Pushes {
        var events: [AgentPaneTransportEvent] = []
        var frames: [String] { events.flatMap(\.frames) }
        var closes: Int { events.count { $0.closed != nil } }
    }

    /// Waits for an async step (a frame arriving on the socket's queue, the server seeing the close).
    static func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    static func rig(_ pushes: Pushes, hidden: Bool = true) -> (AgentPaneTransport, AgentPaneFramePacer) {
        let pacer = AgentPaneFramePacer(frames: AgentPaneHiddenPacingTests.Ticks(), fallback: AgentPaneHiddenHoldTests.SoonDeadline(),
                                        nextTurn: { work in Task { @MainActor in work() } }, isHidden: { hidden })
        let transport = AgentPaneTransport(pacer: pacer)
        transport.promptJournal = nil
        transport.deliver = { event, done in
            pushes.events.append(event)
            // task-owner: the page's completion, a turn later as in the app
            Task { @MainActor in done() }
        }
        return (transport, pacer)
    }

    @Test func aFrozenIdleChatHoldsNoConnectionAndItsThawHandsOnEveryFrameThenTheClose() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let pushes = Pushes()
        let (transport, pacer) = Self.rig(pushes)
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        await Self.settle { pushes.frames.contains { $0.contains(#""id":0"#) } }

        // Frozen: a frame that arrives waits, then the connection closes.
        pacer.pageDidFreeze()
        let before = pushes.events.count
        server.push(AcpmuxStandInServer.benchFrame(1), to: 0)
        await Self.settle { transport.queuedFrames == 1 }
        #expect(transport.queuedFrames == 1, "the frame that arrived before the freeze's close did not wait")
        transport.closeWhileFrozen()
        #expect(transport.closedForFreeze == id)
        await Self.settle { server.peers.first?.closed == true }
        #expect(server.peers.first?.closed == true, "the frozen chat still holds its acpmux connection")
        #expect(server.peers.count { !$0.closed } == 0)
        #expect(pushes.events.count == before, "the frozen page got a call")

        // The thaw: the frame, then the close, in one call.
        transport.pageDidThaw()
        pacer.pageDidThaw()
        await Self.settle { pushes.closes == 1 }
        let thaw = Array(pushes.events.dropFirst(before))
        #expect(thaw.count == 1, "the thaw took \(thaw.count) calls")
        #expect(thaw.first?.frames.contains { $0.contains(#""s":1,"#) } == true, "the frame before the close was lost")
        #expect(thaw.first?.closed?.code == 1000)
        #expect(thaw.first?.closed?.reason == AgentPaneTransport.pageFrozenCloseReason, "the page cannot tell the freeze's close from a lost daemon")
        #expect(transport.connection == nil)

        // The page's one reconnect.
        let again = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(again != id)
        #expect(transport.freezeReconnects == 1)
        #expect(transport.closedForFreeze == nil)
        #expect(server.peers.count == 2)
        #expect(server.peers.count { !$0.closed } == 1)
    }

    /// A send still in line when the page froze goes first; the close follows once the line is empty. A
    /// thaw before then leaves the connection open.
    @Test func aSendInLineGoesBeforeTheFreezesCloseAndAThawCancelsIt() {
        let pushes = Pushes()
        let (transport, pacer) = Self.rig(pushes)
        Self.attachUnstartedSocket(to: transport)
        pacer.pageDidFreeze()

        transport.draining = true
        transport.closeWhileFrozen()
        #expect(transport.closedForFreeze == nil, "the close went before the send in line")
        transport.draining = false
        transport.sendLineDidEmpty()
        #expect(transport.closedForFreeze == 1)

        let (other, otherPacer) = Self.rig(pushes)
        Self.attachUnstartedSocket(to: other)
        otherPacer.pageDidFreeze()
        other.draining = true
        other.closeWhileFrozen()
        other.pageDidThaw()
        otherPacer.pageDidThaw()
        other.draining = false
        other.sendLineDidEmpty()
        #expect(other.closedForFreeze == nil, "a thawed page's connection closed")
        #expect(other.connection == 1)
    }

    /// A pane that comes into sight thaws its pacer itself (``AgentPaneFramePacer/visibilityChanged()``),
    /// with no lifecycle thaw telling the transport: a freeze's close still waiting for the send line must
    /// not close the visible page's connection when the line empties.
    @Test func aPacerThawWhileASendDrainsLeavesTheConnectionOpen() {
        let pushes = Pushes()
        let (transport, pacer) = Self.rig(pushes, hidden: false)
        Self.attachUnstartedSocket(to: transport)
        pacer.pageDidFreeze()
        transport.draining = true
        transport.closeWhileFrozen()
        #expect(transport.closedForFreeze == nil)

        pacer.visibilityChanged()
        #expect(!pacer.pageFrozen, "the pane in sight stayed frozen")
        transport.draining = false
        transport.sendLineDidEmpty()
        #expect(transport.closedForFreeze == nil, "a visible page's connection closed for a freeze that ended")
        #expect(transport.connection == 1)
    }

    /// A transport on connection 1 whose socket never connects (no frame goes anywhere). Its wake reaches
    /// the transport as an open socket's does, so a close reaches the pacer.
    static func attachUnstartedSocket(to transport: AgentPaneTransport) {
        transport.socket = AcpmuxPaneSocket(request: URLRequest(url: URL(string: "ws://127.0.0.1")!), limits: transport.limits,
                                            options: transport.permissionOptions, sessions: transport.sessions,
                                            ids: AcpmuxRequestIds()) { [weak transport] in
            // task-owner: one wake for the pacer, as the transport's own socket gives
            Task { @MainActor [weak transport] in transport?.arrived(1) }
        }
        transport.current = 1
    }
}
