import Foundation
import Testing
@testable import CmuxNextAgentPane

/// hq#2569 item 5 follow-up, at the relay boundary (the page's frames into ``AgentPaneTransport``):
/// a new chat's first prompt waits for its harness to start (a New Tab ask, a harness switch, the
/// composer's Enter in a new chat). The person's send gesture lives 30 s, and a harness that cannot
/// reach its backend can take longer to answer `session/new`, so the prompt reached the relay with
/// no gesture left and came back `transport.gesture_required`: "Not sent". The start that took the
/// person's gesture now carries it to that chat's first prompt, as a start on another machine does,
/// once and within the start credit's lifetime.
@Suite(.serialized)
@MainActor
struct AgentPaneSlowStartPromptTests {
    final class Clock { var now: TimeInterval = 1000 }

    struct Pane {
        let server: AcpmuxStandInServer
        let transport: AgentPaneTransport
        let inbox: AgentPaneRelayedAllowTests.PageInbox
        let clock: Clock
        let folder: String
        let id: Int
    }

    static func pane() async throws -> Pane {
        let server = AcpmuxStandInServer()
        try await server.start()
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("slow-start-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let clock = Clock()
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport(gestures: AgentPaneUserGestures(now: { clock.now }))
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.roots = { [folder] }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        return Pane(server: server, transport: transport, inbox: inbox, clock: clock, folder: folder, id: id)
    }

    static func start(_ pane: Pane, id: Int) async -> AgentPaneTransportError? {
        let frame = #"{"jsonrpc":"2.0","id":\#(id),"method":"session/new","params":{"cwd":"\#(pane.folder)","mcpServers":[]}}"#
        let error = await pane.transport.send(connection: pane.id, frames: [frame])
        // acpmux's answer names the new chat (the stand-in's `s-new`): the pane's own session now.
        if error == nil { _ = await pane.inbox.frame(containing: #""id":\#(id)"#) }
        return error
    }

    static func prompt(id: Int, promptId: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"text","text":"Add a remove command"}],"_meta":{"acpmux":{"promptId":"\#(promptId)"}}}}"#
    }

    @Test func aPromptQueuedBehindASlowStartGoesWithTheSendsGesture() async throws {
        let pane = try await Self.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        // The person's Enter starts the chat; the harness takes 45 s to answer.
        pane.transport.gestures.record()
        #expect(await Self.start(pane, id: 1) == nil)
        pane.clock.now += 45
        #expect(!pane.transport.gestures.isAvailable, "the test needs the live gesture to have expired")

        let sent = await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 2, promptId: "p-1")])
        #expect(sent == nil, "the chat's first prompt lost the gesture its send started the chat with")
        guard sent == nil else { return }
        _ = await pane.inbox.frame(containing: #""id":2"#)
        #expect(pane.server.peers.first?.frames.contains { $0.contains("session/prompt") } == true)

        // One grant per gesture: a second prompt with no new gesture is refused.
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 3, promptId: "p-2")]) == .gestureRequired)
    }

    @Test func aStartWithoutTheGestureCarriesNothingAndTheCreditEnds() async throws {
        let pane = try await Self.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        // A start the page made by itself (no gesture of the person's) gives its prompt nothing.
        #expect(await Self.start(pane, id: 1) == nil)
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 2, promptId: "p-1")]) == .gestureRequired)

        // A start under the gesture whose prompt comes after the credit's lifetime is refused too.
        pane.transport.gestures.record()
        #expect(await Self.start(pane, id: 3) == nil)
        pane.clock.now += AgentPaneTransport.startCreditLifetime + 1
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 4, promptId: "p-2")]) == .gestureRequired)
    }

    /// #23031: a harness pick starts the chat at once, and the prompt the person sends while it
    /// starts waits in the page (harnessSwitch.ts) until the session opens. A cold harness can
    /// outlast both the Enter's gesture and the pick's start credit; the prompt then came back
    /// "Not sent. Press Retry". The page now reserves the Enter's gesture as the prompt's ticket.
    @Test func aPromptHeldBehindAStartThatOutlastsTheGestureGoesWithTheTicketItsEnterTook() async throws {
        let pane = try await Self.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        // The pick starts the chat; the person types for 20 s and presses Enter while it starts.
        pane.transport.gestures.record(click: true)
        #expect(await Self.start(pane, id: 1) == nil)
        pane.clock.now += 20
        pane.transport.gestures.record()
        let request: [String: Any] = ["method": "session/prompt", "params": ["promptId": "p-1"] as [String: Any]]
        let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": request]))
        let ticket = try #require(pane.transport.reserveGesture(intent), "the Enter's live gesture gave no ticket")
        // The harness answers 130 s after the pick: the gesture and the start credit are gone.
        pane.clock.now += 110

        // Sent with no ticket, as before the fix, the prompt is refused.
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 2, promptId: "p-1")]) == .gestureRequired)
        // With the Enter's ticket it goes, once.
        let frame = #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"text","text":"Add a remove command"}],"_meta":{"acpmux":{"promptId":"p-1"},"cmuxGesture":"\#(ticket)"}}}"#
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) == nil)
        _ = await pane.inbox.frame(containing: #""id":3"#)
        #expect(pane.server.peers.first?.frames.contains { $0.contains("session/prompt") } == true)
        let replay = frame.replacingOccurrences(of: #""id":3"#, with: #""id":4"#)
        #expect(await pane.transport.send(connection: pane.id, frames: [replay]) == .gestureRequired)
    }

    /// The same, with the start answering inside the start credit's lifetime: the ticketed prompt
    /// spends the start's credit too, so a later prompt with no gesture is refused (one grant per
    /// gesture), never granted by the credit the ticket left behind.
    @Test func aTicketedFirstPromptSpendsTheStartsCredit() async throws {
        let pane = try await Self.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.transport.gestures.record(click: true)
        #expect(await Self.start(pane, id: 1) == nil)
        pane.clock.now += 20
        pane.transport.gestures.record()
        let request: [String: Any] = ["method": "session/prompt", "params": ["promptId": "p-1"] as [String: Any]]
        let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": request]))
        let ticket = try #require(pane.transport.reserveGesture(intent))
        pane.clock.now += 20
        let frame = #"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"text","text":"Add a remove command"}],"_meta":{"acpmux":{"promptId":"p-1"},"cmuxGesture":"\#(ticket)"}}}"#
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) == nil)
        #expect(await pane.transport.send(connection: pane.id, frames: [Self.prompt(id: 3, promptId: "p-2")]) == .gestureRequired)
    }

    /// A prompt acpmux held for the folder trust answer keeps the send's gesture as a ticket
    /// (heldPrompt.ts reserves it at the refusal). The start already took that gesture, so its
    /// credit becomes the ticket, which waits for the answer as long as a held prompt does.
    @Test func aPromptHeldForTrustAfterTheStartStillGetsItsTicket() async throws {
        let pane = try await Self.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }

        pane.transport.gestures.record()
        #expect(await Self.start(pane, id: 1) == nil)
        let request: [String: Any] = ["method": "session/prompt", "params": ["promptId": "p-1"] as [String: Any]]
        let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": request]))
        let ticket = try #require(pane.transport.reserveGesture(intent), "the held prompt got no ticket from its send's gesture")
        // The person takes five minutes over the Trust question.
        pane.clock.now += 300
        let frame = #"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"text","text":"Add a remove command"}],"_meta":{"acpmux":{"promptId":"p-1"},"cmuxGesture":"\#(ticket)"}}}"#
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) == nil)
        // The credit went into the ticket: a second ticket needs a new gesture.
        #expect(pane.transport.reserveGesture(intent) == nil)
    }
}
