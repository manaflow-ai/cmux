import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A Send on the New Tab page with a project picked (a fresh workspace, whose own folder is `~`):
/// the page asks the host to use the folder (`workspace.useFolder`) in the same turn as the Send,
/// then starts the chat there and sends its first prompt. The pick spent the Send's only gesture to
/// make the folder a root, so the start carried none and the first prompt came back
/// `transport.gesture_required`: "Not sent. Press Retry to send it." The gesture a pick spends now
/// goes on to the chat's start and first prompt, as a start's own gesture does.
@Suite(.serialized)
@MainActor
struct AgentPaneSendPickedFolderPromptTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    final class Clock { var now: TimeInterval = 1000 }

    struct Pane {
        let server: AcpmuxStandInServer
        let model: AgentPaneModel
        let inbox: AgentPaneRelayedAllowTests.PageInbox
        let clock: Clock
        let folder: String
        /// A folder that is already a root of the pane: a chat the page starts there needs no pick.
        let root: String
        let base: URL
        let id: Int
    }

    /// A pane with no root for `folder` (a project outside the fresh workspace) and one root of its
    /// own (`root`), on a stand-in acpmux.
    private func pane(home: Bool = false) async throws -> Pane {
        let server = AcpmuxStandInServer()
        try await server.start()
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("send-picked-\(UUID().uuidString)")
        let created = base.appendingPathComponent("parity-demo").path
        try FileManager.default.createDirectory(atPath: created, withIntermediateDirectories: true)
        let folder = AcpmuxPathPolicy.canonical(created) ?? created
        let rooted = base.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: rooted, withIntermediateDirectories: true)
        let root = AcpmuxPathPolicy.canonical(rooted) ?? rooted
        let clock = Clock()
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport(gestures: AgentPaneUserGestures(now: { clock.now }))
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let model = AgentPaneModel(host: NoHost(), transport: transport)
        transport.roots = { [root] }
        transport.homeFolder = home ? folder : "/nonexistent-home-\(UUID().uuidString)"
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        return Pane(server: server, model: model, inbox: inbox, clock: clock, folder: folder, root: root, base: base, id: id)
    }

    private func status(_ reply: [String: Any]) -> String? { (reply["value"] as? [String: Any])?["status"] as? String }

    private func start(_ pane: Pane, id: Int, in cwd: String? = nil) async -> AgentPaneTransportError? {
        let frame = #"{"jsonrpc":"2.0","id":\#(id),"method":"session/new","params":{"cwd":"\#(cwd ?? pane.folder)","mcpServers":[]}}"#
        let error = await pane.model.transport.send(connection: pane.id, frames: [frame])
        if error == nil { _ = await pane.inbox.frame(containing: #""id":\#(id)"#) }
        return error
    }

    private func prompt(_ pane: Pane, id: Int) async -> AgentPaneTransportError? {
        let frame = #"{"jsonrpc":"2.0","id":\#(id),"method":"session/prompt","params":{"sessionId":"s-new","prompt":[{"type":"text","text":"Why did my workspace names reset?"}],"_meta":{"acpmux":{"promptId":"p-\#(id)"}}}}"#
        return await pane.model.transport.send(connection: pane.id, frames: [frame])
    }

    @Test func theFirstPromptOfAChatStartedInAFolderTheSendPickedGoesOut() async throws {
        let pane = try await pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }

        // The person's Enter on the New Tab page: the page asks to use the picked project first.
        pane.model.transport.gestures.record()
        #expect(status(await pane.model.respond(to: .useFolder(pane.folder, confirm: false))) == "ok")
        #expect(pane.model.transport.addedRoots == [pane.folder])
        #expect(await start(pane, id: 1) == nil)
        #expect(await prompt(pane, id: 2) == nil, "the pick spent the Send's gesture: the first prompt is Not sent")

        // Still one prompt per gesture: a second prompt with no new gesture is refused.
        #expect(await prompt(pane, id: 3) == .gestureRequired)
    }

    /// Use Home Folder: the click on the question's answer is the gesture, and the held Send then
    /// starts the chat there; its first prompt goes with that click.
    @Test func theFirstPromptAfterUseHomeFolderGoesOut() async throws {
        let pane = try await pane(home: true)
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }

        pane.model.transport.gestures.record()
        #expect(status(await pane.model.respond(to: .useFolder(pane.folder, confirm: false))) == "confirm")
        pane.model.transport.gestures.record(click: true) // Use Home Folder
        #expect(status(await pane.model.respond(to: .useFolder(pane.folder, confirm: true))) == "ok")
        #expect(await start(pane, id: 1) == nil)
        #expect(await prompt(pane, id: 2) == nil, "the answer spent the click: the first prompt is Not sent")
    }

    /// A pick with no person behind it (page script) still grants nothing and carries nothing.
    @Test func aPickWithoutThePersonCarriesNothing() async throws {
        let pane = try await pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }

        #expect(status(await pane.model.respond(to: .useFolder(pane.folder, confirm: false))) == "ok")
        #expect(pane.model.transport.addedRoots.isEmpty)
        // The page then starts a chat by itself in a folder that is already a root: the pick gave
        // that start nothing to carry, so its first prompt still needs the person.
        #expect(await start(pane, id: 1, in: pane.root) == nil)
        #expect(await prompt(pane, id: 2) == .gestureRequired)
    }

    /// A pick passes its gesture only to a chat that starts: with no start after it, a prompt into
    /// the pane's chat gets nothing from it.
    @Test func aPickWithoutAStartGivesAPromptNothing() async throws {
        let pane = try await pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }

        #expect(await start(pane, id: 1, in: pane.root) == nil) // a chat the page started by itself
        pane.model.transport.gestures.record(click: true) // a folder picked in the menu, no Send
        #expect(status(await pane.model.respond(to: .useFolder(pane.folder, confirm: false))) == "ok")
        #expect(pane.model.transport.addedRoots == [pane.folder]) // the pick took the click
        #expect(await prompt(pane, id: 2) == .gestureRequired)
    }

    /// The carried gesture lasts as long as a start's own (``AgentPaneTransport/startCreditLifetime``).
    @Test func theCarriedGestureEndsWithTheStartCredit() async throws {
        let pane = try await pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }

        pane.model.transport.gestures.record()
        #expect(status(await pane.model.respond(to: .useFolder(pane.folder, confirm: false))) == "ok")
        #expect(await start(pane, id: 1) == nil)
        pane.clock.now += AgentPaneTransport.startCreditLifetime + 1
        #expect(await prompt(pane, id: 2) == .gestureRequired)
    }
}
