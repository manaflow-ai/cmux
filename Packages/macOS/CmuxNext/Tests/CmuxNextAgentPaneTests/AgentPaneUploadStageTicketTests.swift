import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A file the page uploads at the person's Send (one too large to go inline in the prompt,
/// webviews promptBudget.ts) begins its `chat.upload.begin` with that Send's ticket
/// (``AgentPaneUploadSendTicket``) instead of spending the gesture: the person's Enter is one
/// credit, and the prompt itself needs it, so an upload that spent it left the prompt refused as
/// `gestureRequired` (#29500). The upload holds the ticket; the prompt redeems it once every
/// upload of it is done. Leo, 2026-10-31: "this is completely hardlocked bc of message size".
@Suite(.serialized)
@MainActor
struct AgentPaneUploadStageTicketTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// What the stand-in stager saw, by kind.
    final class Staged {
        var requests: [AgentPaneUploadStageRequest] = []
        /// The stager's finish fails (the copy did not complete).
        var failFinish = false
        /// Seconds the stager's finish takes on `clock` (a Cloud or peer transfer after the last chunk).
        var finishTakes: TimeInterval = 0
        let clock = AgentPaneUploadSendTicketTests.Clock()
        var cancels: Int { requests.filter { if case .cancel = $0 { true } else { false } }.count }
    }

    private func pane() async throws -> (AcpmuxStandInServer, AgentPaneModel, Int, Staged) {
        let server = AcpmuxStandInServer()
        try await server.start()
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let staged = Staged()
        let transport = AgentPaneTransport(gestures: AgentPaneUserGestures(now: { staged.clock.now }))
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let model = AgentPaneModel(host: NoHost(), transport: transport)
        model.onUploadStage = {
            { request, _ in
                staged.requests.append(request)
                switch request {
                case .begin(_, let size, _, _): return AgentPaneReply.success(["token": "t-1", "size": size, "chunkSize": 512 * 1024])
                case .chunk(_, let offset, let data): return AgentPaneReply.success(["offset": offset + data.count])
                case .finish:
                    staged.clock.now += staged.finishTakes
                    if staged.failFinish { return AgentPaneReply.failure(code: "upload.incomplete", message: "Not completed.") }
                    return AgentPaneReply.success(["path": "/tmp/uploads/big.pdf"])
                case .cancel: return AgentPaneReply.success()
                }
            }
        }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let folder = AcpmuxPathPolicy.canonical(temporary) ?? temporary
        transport.roots = { [folder] }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.gestures.record()
        let start = #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"\#(folder)","mcpServers":[]}}"#
        #expect(await transport.send(connection: id, frames: [start]) == nil)
        _ = await inbox.frame(containing: #""id":1"#)
        return (server, model, id, staged)
    }

    private func sendTicket(_ transport: AgentPaneTransport, promptId: String = "p-1") throws -> String {
        let intent = try #require(AgentPaneGestureIntent(gestureParams: [
            "intent": ["method": "session/prompt", "params": ["promptId": promptId, "sessionId": "s-new"]],
        ]))
        return try #require(transport.reserveGesture(intent))
    }

    private func call(_ model: AgentPaneModel, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private func prompt(_ transport: AgentPaneTransport, _ id: Int, ticket: String, frame: Int) async -> AgentPaneTransportError? {
        let text = #"{"jsonrpc":"2.0","id":\#(frame),"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"resource_link","uri":"file:///tmp/uploads/big.pdf","name":"big.pdf"}],"_meta":{"acpmux":{"promptId":"p-1"},"cmuxGesture":"\#(ticket)"}}}"#
        return await transport.send(connection: id, frames: [text])
    }

    private func ok(_ reply: [String: Any]) -> Bool { reply["ok"] as? Bool == true }

    @Test func aSendsUploadHoldsItsTicketAndThePromptStillGoes() async throws {
        let (server, model, id, staged) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        transport.gestures.record() // the person's Enter
        let ticket = try sendTicket(transport) // the page reserves it for the prompt: the gesture is spent
        #expect(!transport.gestures.isAvailable)
        let send: [String: Any] = ["sessionId": "s-new", "promptId": "p-1", "ticket": ticket]
        let begun = await call(model, "chat.upload.begin", ["name": "big.pdf", "size": 2].merging(send) { $1 })
        #expect(ok(begun), "a send's upload needed a live gesture: \(begun)")
        #expect(ok(await call(model, "chat.upload.chunk", ["token": "t-1", "offset": 0, "data": Data([1, 2]).base64EncodedString()])))
        #expect(ok(await call(model, "chat.upload.finish", ["token": "t-1"])))
        #expect(staged.requests.count == 3)
        #expect(await prompt(transport, id, ticket: ticket, frame: 2) == nil, "the prompt of a send's upload was refused")
        #expect(await prompt(transport, id, ticket: ticket, frame: 3) == .gestureRequired, "one ticket sent two prompts")
    }

    /// The finish of a Cloud or peer upload awaits the transfer, with no page chunk to report progress:
    /// a finish longer than ``AgentPaneUserGestures/uploadStallLimit`` must not stall the hold out.
    @Test func aFinishLongerThanTheStallLimitStillSends() async throws {
        let (server, model, id, staged) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        transport.gestures.record()
        let ticket = try sendTicket(transport)
        staged.finishTakes = AgentPaneUserGestures.uploadStallLimit * 3
        #expect(ok(await begin(model, ticket: ticket)))
        #expect(ok(await call(model, "chat.upload.chunk", ["token": "t-1", "offset": 0, "data": Data([1, 2]).base64EncodedString()])))
        #expect(ok(await call(model, "chat.upload.finish", ["token": "t-1"])))
        #expect(staged.cancels == 0, "a long finish cancelled its own stage")
        #expect(await prompt(transport, id, ticket: ticket, frame: 2) == nil, "a long finish expired the send ticket")
    }

    @Test func anUploadWithAnotherSendsTicketOrNoneIsRefused() async throws {
        let (server, model, _, staged) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        transport.gestures.record()
        let ticket = try sendTicket(transport)
        for send: [String: Any] in [
            ["sessionId": "s-new", "promptId": "p-2", "ticket": ticket], // another prompt
            ["sessionId": "s-other", "promptId": "p-1", "ticket": ticket], // a chat not in the pane
            ["sessionId": "s-new", "promptId": "p-1", "ticket": "forged"],
        ] {
            let begun = await call(model, "chat.upload.begin", ["name": "big.pdf", "size": 2].merging(send) { $1 })
            #expect(!ok(begun), "an upload began on \(send)")
        }
        // No ticket and no gesture left: refused as before. The Enter's own upload credit (one batch
        // of files, ``AgentPaneUserGestures/consumeUpload()``) is not the ticket's; spend it first.
        _ = transport.gestures.consumeUpload()
        #expect(!ok(await call(model, "chat.upload.begin", ["name": "big.pdf", "size": 2])))
        #expect(staged.requests.isEmpty, "a refused upload reached the stager")
    }

    @Test func aCancelledUploadReleasesItsHold() async throws {
        let (server, model, id, _) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        transport.gestures.record()
        let ticket = try sendTicket(transport)
        let send: [String: Any] = ["sessionId": "s-new", "promptId": "p-1", "ticket": ticket]
        #expect(ok(await call(model, "chat.upload.begin", ["name": "big.pdf", "size": 2].merging(send) { $1 })))
        #expect(ok(await call(model, "chat.upload.cancel", ["token": "t-1"])))
        #expect(await prompt(transport, id, ticket: ticket, frame: 2) == nil)
    }

    private func begin(_ model: AgentPaneModel, ticket: String, extra: [String: Any] = [:]) async -> [String: Any] {
        let send: [String: Any] = ["sessionId": "s-new", "promptId": "p-1", "ticket": ticket]
        return await call(model, "chat.upload.begin", ["name": "big.pdf", "size": 2].merging(send) { $1 }.merging(extra) { $1 })
    }

    @Test func aFinishThatFailsCancelsItsStageBeforeTheHoldEnds() async throws {
        let (server, model, _, staged) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        transport.gestures.record()
        let ticket = try sendTicket(transport)
        staged.failFinish = true
        #expect(ok(await begin(model, ticket: ticket)))
        #expect(!ok(await call(model, "chat.upload.finish", ["token": "t-1"])))
        #expect(staged.cancels == 1, "a stage whose finish failed was left to upload after its hold ended")
        #expect(model.uploadHolds.isEmpty)
    }

    @Test func anEmptyChunkIsNoProgressAndEndsTheHeldStage() async throws {
        let (server, model, _, staged) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        transport.gestures.record()
        let ticket = try sendTicket(transport)
        #expect(ok(await begin(model, ticket: ticket)))
        #expect(!ok(await call(model, "chat.upload.chunk", ["token": "t-1", "offset": 0, "data": ""])))
        #expect(!staged.requests.contains { if case .chunk = $0 { true } else { false } }, "an empty chunk reached the stager")
        #expect(staged.cancels == 1)
        #expect(model.uploadHolds.isEmpty)
    }

    @Test func aHeldBeginNamesNoBatch() async throws {
        let (server, model, _, staged) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        transport.gestures.record()
        let ticket = try sendTicket(transport)
        let batch: [[String: Any]] = [["name": "big.pdf", "size": 2], ["name": "more.pdf", "size": 2]]
        #expect(!ok(await begin(model, ticket: ticket, extra: ["batch": batch])))
        #expect(!ok(await begin(model, ticket: ticket, extra: ["batchToken": "b-1"])))
        #expect(staged.requests.isEmpty, "a held begin with a batch reached the stager")
    }

    @Test func aChunkAfterItsTicketEndedCancelsItsStage() async throws {
        let (server, model, _, staged) = try await pane()
        defer { server.stop() }
        let transport = model.transport
        transport.gestures.record()
        let ticket = try sendTicket(transport)
        #expect(ok(await begin(model, ticket: ticket)))
        transport.gestures.clearTickets() // the page's release, a reconnect
        #expect(!ok(await call(model, "chat.upload.chunk", ["token": "t-1", "offset": 0, "data": Data([1, 2]).base64EncodedString()])))
        #expect(!staged.requests.contains { if case .chunk = $0 { true } else { false } }, "a chunk went after its ticket ended")
        #expect(staged.cancels >= 1)
    }
}
