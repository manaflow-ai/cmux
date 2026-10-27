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
    private func pane(home: Bool = false, connected: Bool = true, maximumSendBytes: Int = 64 << 20) async throws -> Pane {
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
        var limits = AgentPaneTransport.Limits()
        limits.maximumOutstandingBytes = maximumSendBytes
        let transport = AgentPaneTransport(limits: limits, gestures: AgentPaneUserGestures(now: { clock.now }))
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let model = AgentPaneModel(host: NoHost(), transport: transport)
        transport.roots = { [root] }
        transport.homeFolder = home ? folder : "/nonexistent-home-\(UUID().uuidString)"
        var id = 0
        if connected {
            id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
            #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        }
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
        #expect(await pane.server.wait { peers in peers.first?.frames.contains { $0.contains("acp.trust.set") && $0.contains(pane.folder) } == true })
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
        #expect(pane.server.peers.first?.frames.contains { $0.contains("acp.trust.set") } != true)
    }

    @Test func aNativeFolderOpenRecordsTrustWithoutGrantingHomeOrAncestorPaths() async throws {
        let pane = try await pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }

        #expect(await pane.model.transport.pick(pane.folder) == pane.folder)
        #expect(await pane.server.wait { peers in peers.first?.frames.contains { $0.contains("acp.trust.set") && $0.contains(pane.folder) } == true })

        let home = pane.model.transport.homeFolder!
        #expect(await pane.model.transport.pick(home) == home)
        #expect(pane.server.peers.first?.frames.filter { $0.contains("acp.trust.set") }.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aPreOpenFolderPickIsAcknowledgedBeforeTheQueuedChatStarts() async throws {
        let pane = try await pane(connected: false)
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }
        #expect(await pane.model.transport.pick(pane.folder) == pane.folder)
        try await startAfterDeferredTrust(pane)
    }

    @Test(.timeLimit(.minutes(1))) func aFolderPickedAfterCloseSurvivesReconnect() async throws {
        let pane = try await pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }
        pane.model.transport.close(connection: pane.id)
        // The native picker completes even though the old connection still has request ids.
        #expect(await pane.model.transport.pick(pane.folder) == pane.folder)
        try await startAfterDeferredTrust(pane)
    }

    @Test(.timeLimit(.minutes(1))) func journalReplayWaitsForDeferredTrustAcknowledgement() async throws {
        let pane = try await pane(connected: false)
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }
        let transport = pane.model.transport
        let daemon = pane.base.appendingPathComponent("acpmux.sock").path
        let journal = AgentPanePromptJournal(url: pane.base.appendingPathComponent("prompts.json"))
        let entry = AgentPanePromptJournal.Entry(daemon: daemon, sessionId: "s-new", promptId: "replay-1",
            params: #"{"sessionId":"s-new","prompt":[{"type":"text","text":"Continue"}],"_meta":{"acpmux":{"promptId":"replay-1"}}}"#, at: Date())
        let owner = UUID()
        let recorded = await Task.detached { journal.record(entry, owner: owner) }.value
        #expect(recorded)
        journal.connectionEnded(owner: owner, byDaemon: false)
        transport.promptJournal = journal
        transport.webModes = { _, _, _ in nil }
        #expect(await transport.pick(pane.folder) == pane.folder)
        pane.server.hold("acp.trust.set")
        let id = try await transport.open(AcpmuxConnection(url: pane.server.url, dashboardToken: "t", localAppToken: nil, socketPath: daemon))
        defer { pane.server.releaseHeld(); transport.close(connection: id) }
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        #expect(await pane.server.wait { $0.last?.frames.contains { $0.contains("acp.trust.set") } == true })
        #expect(pane.server.peers.last?.frames.contains { $0.contains("session/prompt") } == false)
        #expect(journal.entries().count == 1)
        pane.server.releaseHeld()
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/status","params":{}}"#]) == nil)
        #expect(await pane.server.wait { $0.last?.frames.contains { $0.contains("session/prompt") && $0.contains("replay-1") } == true })
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aTrustSendFailureKeepsTheFolderForReconnect(overflow: Bool) async throws {
        let pane = try await pane(maximumSendBytes: 1024)
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }
        let transport = pane.model.transport
        let socket = try #require(transport.socket)
        let ids = try #require(transport.requestIds)
        if !overflow { socket.close(code: 1000, reason: "", error: nil) }
        // Exercise a failure after the picker has queued its host request, at the actual send.
        let host = AgentPaneTransport.PendingHostSend(connection: pane.id, requestID: ids.hostID(), folder: pane.folder,
            frame: overflow ? String(repeating: " ", count: 1025) : "{}", reply: nil)
        await transport.sendHost(host, socket: socket, ids: ids)
        try await startAfterDeferredTrust(pane)
    }

    private func startAfterDeferredTrust(_ pane: Pane) async throws {
        let transport = pane.model.transport
        pane.server.hold("acp.trust.set")
        let id = try await transport.open(AcpmuxConnection(url: pane.server.url, dashboardToken: "t", localAppToken: nil))
        defer { pane.server.releaseHeld(); transport.close(connection: id) }
        let start = #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"\#(pane.folder)","mcpServers":[]}}"#
        // Both frames already wait when initialization begins. The start must still wait for trust.
        let sending = Task { await transport.send(connection: id, frames: [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#, start,
        ]) }
        #expect(await pane.server.wait { $0.last?.frames.contains { $0.contains("acp.trust.set") } == true })
        #expect(pane.server.peers.last?.frames.contains { $0.contains("session/new") } == false)
        pane.server.releaseHeld()
        #expect(await sending.value == nil)
        #expect(await pane.server.wait { $0.last?.frames.contains { $0.contains("session/new") } == true })
    }

    @Test func choosingAFolderNativelyRecordsTrustAfterThePanelConsumesItsGesture() async throws {
        let pane = try await pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }
        pane.model.onChooseFolder = { .chosen(pane.folder) }
        pane.model.transport.gestures.record(click: true)
        _ = await pane.model.respond(to: .chooseFolder)
        #expect(await pane.server.wait { $0.first?.frames.contains { $0.contains("acp.trust.set") && $0.contains(pane.folder) } == true })
        #expect(await start(pane, id: 1) == nil)
        #expect(await prompt(pane, id: 2) == nil)
    }

    @Test func pickingAnExistingRootCarriesTheSendGesture() async throws {
        let pane = try await pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(at: pane.base) }
        pane.model.transport.gestures.record()
        #expect(status(await pane.model.respond(to: .useFolder(pane.root, confirm: false))) == "ok")
        #expect(await start(pane, id: 1, in: pane.root) == nil)
        #expect(await prompt(pane, id: 2) == nil)
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
