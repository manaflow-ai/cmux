import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The send ticket an upload holds (``AgentPaneUploadSendTicket``): a file of any size, uploaded
/// after the person's Send, still sends, and the ticket stays exactly one prompt's, once (Leo,
/// 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE").
@Suite(.serialized)
@MainActor
struct AgentPaneUploadSendTicketTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    final class Clock { var now: TimeInterval = 1000 }

    final class Ended { var uploads = Set<String>() }

    private func intent(promptId: String = "p-1", sessionId: String? = "s-1") throws -> AgentPaneGestureIntent {
        var params: [String: Any] = ["promptId": promptId]
        if let sessionId { params["sessionId"] = sessionId }
        return try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": params]]))
    }

    private func prompt(_ promptId: String = "p-1") -> AgentPaneGesturePick {
        AgentPaneGesturePick(method: "session/prompt", params: ["_meta": ["acpmux": ["promptId": promptId]]])
    }

    /// Gestures on a clock, a send ticket reserved at the person's Send, and what the holds report.
    private func reserved(_ clock: Clock = Clock(), intent: AgentPaneGestureIntent? = nil) throws
        -> (AgentPaneUserGestures, String, Ended) {
        let gestures = AgentPaneUserGestures(now: { clock.now })
        let ended = Ended()
        gestures.onUploadHoldsEnded = { ended.uploads.formUnion($0) }
        gestures.record()
        let ticket = try #require(gestures.reserve(connection: 1, intent: intent ?? self.intent()))
        return (gestures, ticket, ended)
    }

    /// Advances `clock` by `seconds`, each upload reporting progress every 30 s as its chunks land.
    private func upload(_ gestures: AgentPaneUserGestures, _ uploads: String..., for seconds: TimeInterval, clock: Clock) {
        var left = seconds
        while left > 0 {
            let step = min(30, left)
            clock.now += step
            left -= step
            for upload in uploads { #expect(gestures.uploadProgressed(upload), "an upload in progress lost its hold") }
        }
    }

    @Test func theIntentBindsASendTicketToItsChatOnly() throws {
        let bound = try intent()
        #expect(bound.sessionId == "s-1")
        #expect(bound.params == ["promptId": .string("p-1")], "the chat became part of the pick")
        #expect(try intent(sessionId: nil).sessionId == nil)
        let mode: [String: Any] = ["intent": ["method": "session/set_mode", "params": ["modeId": "plan", "sessionId": "s-1"]]]
        #expect(AgentPaneGestureIntent(gestureParams: mode) == nil, "a mode pick took a chat binding")
        let number: [String: Any] = ["intent": ["method": "session/prompt", "params": ["promptId": "p-1", "sessionId": 7]]]
        #expect(AgentPaneGestureIntent(gestureParams: number) == nil)
    }

    @Test func theBeginParamsCarryTheTicketPromptAndChat() {
        let params: [String: Any] = ["token": "t", "name": "a.bin", "size": 3, "sessionId": "s-1", "promptId": "p-1", "ticket": "k"]
        #expect(AgentPaneUploadSendTicket(beginParams: params) == AgentPaneUploadSendTicket(sessionId: "s-1", promptId: "p-1", ticket: "k"))
        for key in ["sessionId", "promptId", "ticket"] {
            var missing = params
            missing.removeValue(forKey: key)
            #expect(AgentPaneUploadSendTicket(beginParams: missing) == nil, "an upload began without \(key)")
            missing[key] = ""
            #expect(AgentPaneUploadSendTicket(beginParams: missing) == nil, "an upload began with an empty \(key)")
        }
    }

    /// Two files, each far longer than a gesture (30 s) and the ticket's own lifetime: the prompt
    /// still redeems the ticket after both finish.
    @Test func anUploadLongerThanTheTicketStillSends() throws {
        let clock = Clock()
        let (gestures, ticket, ended) = try reserved(clock)
        #expect(gestures.holdForUpload(ticket, upload: "u-1", connection: 1, sessionId: "s-1", promptId: "p-1"))
        #expect(gestures.holdForUpload(ticket, upload: "u-2", connection: 1, sessionId: "s-1", promptId: "p-1"))
        upload(gestures, "u-1", "u-2", for: AgentPaneUserGestures.heldPromptLifetime + 600, clock: clock)
        #expect(gestures.releaseUpload("u-1"))
        upload(gestures, "u-2", for: 3600, clock: clock)
        #expect(gestures.releaseUpload("u-2"))
        clock.now += 20
        #expect(gestures.redeem(ticket, connection: 1, pick: prompt(), sessionId: "s-1"), "a long upload's prompt was refused")
        #expect(ended.uploads.isEmpty)

        // Control: the same wait with no upload holding the ticket expires it.
        let control = Clock()
        let (other, unheld, _) = try reserved(control)
        control.now += AgentPaneUserGestures.heldPromptLifetime + 1
        #expect(!other.redeem(unheld, connection: 1, pick: prompt(), sessionId: "s-1"))
    }

    @Test func anExpiredReusedOrForeignTicketHoldsNoUpload() throws {
        let clock = Clock()
        let (gestures, ticket, _) = try reserved(clock)
        #expect(!gestures.holdForUpload(ticket, upload: "u", connection: 2, sessionId: "s-1", promptId: "p-1"), "another connection")
        #expect(!gestures.holdForUpload(ticket, upload: "u", connection: 1, sessionId: "s-2", promptId: "p-1"), "another chat")
        #expect(!gestures.holdForUpload(ticket, upload: "u", connection: 1, sessionId: "s-1", promptId: "p-2"), "another prompt")
        #expect(!gestures.holdForUpload("forged", upload: "u", connection: 1, sessionId: "s-1", promptId: "p-1"))
        #expect(gestures.holdForUpload(ticket, upload: "u", connection: 1, sessionId: "s-1", promptId: "p-1"))
        #expect(!gestures.holdForUpload(ticket, upload: "u", connection: 1, sessionId: "s-1", promptId: "p-1"), "one upload held twice")
        #expect(gestures.releaseUpload("u"))

        // A ticket bound to no chat (a prompt held for the trust answer) holds no upload.
        let (unbound, loose, _) = try reserved(intent: intent(sessionId: nil))
        #expect(!unbound.holdForUpload(loose, upload: "u", connection: 1, sessionId: "s-1", promptId: "p-1"))

        // Used once: a redeemed ticket neither redeems again nor holds an upload.
        #expect(gestures.redeem(ticket, connection: 1, pick: prompt(), sessionId: "s-1"))
        #expect(!gestures.redeem(ticket, connection: 1, pick: prompt(), sessionId: "s-1"))
        #expect(!gestures.holdForUpload(ticket, upload: "v", connection: 1, sessionId: "s-1", promptId: "p-1"))

        // Expired before its upload began.
        let (late, stale, _) = try reserved(clock)
        clock.now += AgentPaneUserGestures.heldPromptLifetime + 1
        #expect(!late.holdForUpload(stale, upload: "u", connection: 1, sessionId: "s-1", promptId: "p-1"))
    }

    @Test func onlyItsOwnPromptInItsOwnChatRedeemsItOnceItsUploadsEnded() throws {
        let (gestures, ticket, _) = try reserved()
        #expect(!gestures.redeem(ticket, connection: 1, pick: prompt(), sessionId: "s-2"), "a prompt to another chat")
        let (other, second, _) = try reserved()
        #expect(!other.redeem(second, connection: 1, pick: prompt("p-2"), sessionId: "s-1"), "another prompt")

        // A prompt sent while an upload still holds the ticket spends it and ends the hold.
        let (held, third, ended) = try reserved()
        #expect(held.holdForUpload(third, upload: "u", connection: 1, sessionId: "s-1", promptId: "p-1"))
        #expect(!held.redeem(third, connection: 1, pick: prompt(), sessionId: "s-1"))
        #expect(ended.uploads == ["u"] && !held.holdsTicket(upload: "u"))
    }

    /// A stalled upload holds the ticket no longer than ``AgentPaneUserGestures/uploadStallLimit``.
    @Test func aStalledUploadEndsItsHold() throws {
        let clock = Clock()
        let (gestures, ticket, ended) = try reserved(clock)
        #expect(gestures.holdForUpload(ticket, upload: "u", connection: 1, sessionId: "s-1", promptId: "p-1"))
        clock.now += AgentPaneUserGestures.uploadStallLimit + 1
        #expect(!gestures.uploadProgressed("u"))
        #expect(ended.uploads == ["u"])
        #expect(!gestures.releaseUpload("u"))
        #expect(!gestures.redeem(ticket, connection: 1, pick: prompt(), sessionId: "s-1"))
    }

    /// Each upload has its own stall clock: another upload's progress, or a new upload, never keeps
    /// a stalled one's hold alive.
    @Test func oneStalledUploadEndsTheHoldEvenBesideAnActiveOne() throws {
        let clock = Clock()
        let (gestures, ticket, ended) = try reserved(clock)
        #expect(gestures.holdForUpload(ticket, upload: "stalled", connection: 1, sessionId: "s-1", promptId: "p-1"))
        #expect(gestures.holdForUpload(ticket, upload: "active", connection: 1, sessionId: "s-1", promptId: "p-1"))
        clock.now += 40
        #expect(gestures.uploadProgressed("active"))
        #expect(gestures.holdForUpload(ticket, upload: "fresh", connection: 1, sessionId: "s-1", promptId: "p-1"))
        clock.now += AgentPaneUserGestures.uploadStallLimit - 40 + 1
        #expect(!gestures.uploadProgressed("active"), "the active upload kept a stalled one's hold alive")
        #expect(ended.uploads == ["stalled", "active", "fresh"])
        #expect(!gestures.redeem(ticket, connection: 1, pick: prompt(), sessionId: "s-1"))
    }

    /// Finish and cancel release the hold, and the ticket's clock runs again from where it stopped.
    @Test func finishOrCancelReleasesTheHoldAndTheClockRunsAgain() throws {
        let clock = Clock()
        let (gestures, ticket, ended) = try reserved(clock)
        clock.now += 100
        #expect(gestures.holdForUpload(ticket, upload: "u", connection: 1, sessionId: "s-1", promptId: "p-1"))
        upload(gestures, "u", for: 900, clock: clock)
        #expect(gestures.releaseUpload("u"))
        #expect(!gestures.holdsTicket(upload: "u") && !gestures.releaseUpload("u") && !gestures.uploadProgressed("u"))
        #expect(ended.uploads.isEmpty, "a finished upload was reported as dropped")
        clock.now += AgentPaneUserGestures.heldPromptLifetime - 100 + 1
        #expect(!gestures.redeem(ticket, connection: 1, pick: prompt(), sessionId: "s-1"), "the clock did not run again after the upload")
    }

    /// Each prompt keeps its own ticket during a burst. A same-prompt replacement, the page's
    /// release, a prompt that went out and the connection's end drop the ticket: each reports the
    /// uploads it held.
    @Test func replacementReleaseAndConnectionEndDropTheHolds() throws {
        let (gestures, ticket, ended) = try reserved()
        #expect(gestures.holdForUpload(ticket, upload: "a", connection: 1, sessionId: "s-1", promptId: "p-1"))
        gestures.record()
        let newer = try #require(gestures.reserve(connection: 1, intent: intent(promptId: "p-2")))
        #expect(ended.uploads.isEmpty && gestures.holdsTicket(upload: "a"), "a different prompt replaced an unrelated ticket")

        #expect(gestures.holdForUpload(newer, upload: "b", connection: 1, sessionId: "s-1", promptId: "p-2"))
        gestures.record()
        _ = try #require(gestures.reserve(connection: 1, intent: intent(promptId: "p-2")))
        #expect(ended.uploads == ["b"] && gestures.holdsTicket(upload: "a"), "a same-prompt replacement did not drop its upload")
        gestures.clearTickets() // a prompt went out, or the page released its tickets
        #expect(ended.uploads == ["a", "b"] && !gestures.holdsTicket(upload: "b") && !gestures.holdsTicket(upload: "a"))

        gestures.record()
        let third = try #require(gestures.reserve(connection: 1, intent: intent(promptId: "p-3")))
        #expect(gestures.holdForUpload(third, upload: "c", connection: 1, sessionId: "s-1", promptId: "p-3"))
        gestures.clearTickets(connection: 2)
        #expect(gestures.holdsTicket(upload: "c"), "another connection's end dropped this one's hold")
        gestures.clearTickets(connection: 1)
        #expect(ended.uploads == ["a", "b", "c"] && !gestures.holdsTicket(upload: "c"))
    }

    // MARK: Through the transport, on a stand-in acpmux

    private func pane() async throws -> (AcpmuxStandInServer, AgentPaneModel, Clock, Int) {
        let server = AcpmuxStandInServer()
        try await server.start()
        let clock = Clock()
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport(gestures: AgentPaneUserGestures(now: { clock.now }))
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let model = AgentPaneModel(host: NoHost(), transport: transport)
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let folder = AcpmuxPathPolicy.canonical(temporary) ?? temporary
        transport.roots = { [folder] }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.gestures.record()
        let start = #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"\#(folder)","mcpServers":[]}}"#
        #expect(await transport.send(connection: id, frames: [start]) == nil)
        _ = await inbox.frame(containing: #""id":1"#)
        return (server, model, clock, id)
    }

    private func send(_ transport: AgentPaneTransport, _ id: Int, ticket: String, frame: Int) async -> AgentPaneTransportError? {
        let text = #"{"jsonrpc":"2.0","id":\#(frame),"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"text","text":"see the files"}],"_meta":{"acpmux":{"promptId":"p-1"},"cmuxGesture":"\#(ticket)"}}}"#
        return await transport.send(connection: id, frames: [text])
    }

    @Test func aPromptWhoseUploadTookAnHourGoesOutAndOnlyOnce() async throws {
        let (server, model, clock, id) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        #expect(transport.sessions.contains("s-new"))
        transport.gestures.record() // the person's Send
        let ticket = try #require(transport.reserveGesture(intent(sessionId: "s-new")))
        #expect(!transport.holdSendTicket(ticket, upload: "u", sessionId: "s-other", promptId: "p-1"), "a chat not in the pane")
        #expect(transport.holdSendTicket(ticket, upload: "u", sessionId: "s-new", promptId: "p-1"))
        upload(transport.gestures, "u", for: 3600, clock: clock)
        #expect(transport.gestures.releaseUpload("u"))
        #expect(!transport.gestures.isAvailable, "the test would pass on a live gesture")
        #expect(await send(transport, id, ticket: ticket, frame: 2) == nil, "the prompt of a long upload was refused")
        #expect(await send(transport, id, ticket: ticket, frame: 3) == .gestureRequired, "one ticket sent two prompts")
    }

    @Test func theConnectionsEndDropsItsHolds() async throws {
        let (server, model, _, id) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        let ended = Ended()
        transport.gestures.onUploadHoldsEnded = { ended.uploads.formUnion($0) }
        transport.gestures.record()
        let ticket = try #require(transport.reserveGesture(intent(sessionId: "s-new")))
        #expect(transport.holdSendTicket(ticket, upload: "u", sessionId: "s-new", promptId: "p-1"))
        transport.close(connection: id)
        #expect(ended.uploads == ["u"] && !transport.gestures.holdsTicket(upload: "u"))
        #expect(!transport.holdSendTicket(ticket, upload: "v", sessionId: "s-new", promptId: "p-1"))
    }
}
