import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Flushes only when the test says so.
@MainActor private final class ManualPacer: AgentPaneTransportPacer {
    var pending: (@MainActor @Sendable () -> AgentPaneFlush)?
    func schedule(_ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush) { pending = flush }
    func drain() { while let pending, pending().more {} ; pending = nil }
}

/// A host whose LocalApp token is read from a file at each handshake, as AcpmuxHost reads
/// `ACPMUX_HOME/run/localapp.token`.
private actor FileTokenHost: AgentPaneHostProviding {
    let url: URL
    let home: URL
    init(url: URL, home: URL) { self.url = url; self.home = home }
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(AcpmuxConnection(endpoint: AcpmuxWebEndpoint(url: url, token: "dash-token"), home: home), sessionId: sessionId)
    }
}

@MainActor
@Suite(.serialized) struct AgentPaneTransportTests {
    nonisolated static let localApp = String(repeating: "a1", count: 32)
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}"#

    private func connection(_ server: AcpmuxStandInServer, localApp: String? = localApp) -> AcpmuxConnection {
        AcpmuxConnection(url: server.url, dashboardToken: "dash-token", localAppToken: localApp)
    }

    /// Waits for `condition` while the main actor keeps running.
    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func theHostSocketCarriesTheBearerAndThePaneOriginAndTheTokenOnlyInTheFirstFrame() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(connection(server))
        #expect(await transport.send(connection: id, frames: [Self.initialize]) == nil)
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/watch","params":{"enabled":true}}"#]) == nil)
        #expect(await server.wait { $0.first?.frames.count == 2 })
        let peer = try #require(server.peers.first)
        #expect(peer.authorization == "Bearer dash-token")
        #expect(peer.origin == AcpmuxConnection.paneOrigin)
        #expect(peer.frames[0].contains(Self.localApp))
        #expect(!peer.frames[1].contains(Self.localApp))
        // The replies reach the page; none of them carries a token.
        #expect(await eventually { events.flatMap(\.frames).count == 2 })
        #expect(!events.flatMap(\.frames).contains { $0.contains(Self.localApp) || $0.contains("dash-token") })
        #expect(!events.map(\.script).contains { $0.contains(Self.localApp) || $0.contains("dash-token") })
    }

    @Test func aMethodNotOnTheListNeverReachesTheDaemonAndIsAnsweredWithATypedError() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(connection(server))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        let refused = #"{"jsonrpc":"2.0","id":9,"method":"_acpmux/peer_add","params":{"url":"ssh://-oProxyCommand=x"}}"#
        #expect(await transport.send(connection: id, frames: [refused]) == .methodRefused)
        let allowed = #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}}"#
        #expect(await transport.send(connection: id, frames: [allowed]) == nil)
        #expect(await server.wait { $0.first?.frames.count == 2 })
        #expect(server.peers.first?.frames.contains { $0.contains("peer_add") } == false)
        // The page's request 9 gets an error frame from the host, so it does not hang.
        #expect(await eventually { events.flatMap(\.frames).contains { $0.contains(#""id":9"#) && $0.contains("transport.method_refused") } })
    }

    @Test func aFirstFrameThatIsNotInitializeClosesTheSocket() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(connection(server))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#]) == .firstFrameNotInitialize)
        #expect(await eventually { events.contains { $0.closed?.error == .firstFrameNotInitialize } })
        #expect(server.peers.first?.frames.isEmpty == true)
        #expect(transport.connection == nil)
    }

    @Test func aPageThatFallsBehindIsClosedWithAnOverflowError() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        var limits = AgentPaneTransport.Limits()
        limits.maximumQueuedFrames = 100
        let pacer = ManualPacer()
        let transport = AgentPaneTransport(limits: limits, pacer: pacer)
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(connection(server))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        #expect(await server.wait { $0.first?.frames.count == 1 })
        // The page takes nothing (the pacer never flushes) while the daemon sends 150 frames.
        for seq in 0..<150 { server.push(#"{"jsonrpc":"2.0","method":"session/update","params":{"s":\#(seq)}}"#, to: 0) }
        #expect(await server.wait { $0.first?.closed == true })
        pacer.drain()
        let close = try #require(events.last?.closed)
        #expect(close.error == .inboundOverflow)
        #expect(transport.connection == nil)
        #expect(await transport.send(connection: id, frames: [Self.initialize]) == .staleConnection)
    }

    @Test func aBurstReachesThePageInOrderInBatches() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let pacer = ManualPacer()
        let transport = AgentPaneTransport(pacer: pacer)
        var frames: [String] = []
        transport.deliver = { event, done in frames += event.frames; done() }
        let id = try await transport.open(connection(server))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        #expect(await eventually { transport.queuedFrames == 1 })
        pacer.drain()
        let before = transport.flushes
        for seq in 0..<2000 { server.push(#"{"jsonrpc":"2.0","method":"session/update","params":{"s":\#(seq)}}"#, to: 0) }
        #expect(await eventually { transport.queuedFrames == 2000 })
        pacer.drain()
        #expect(frames.count == 2001)
        let seqs = frames.dropFirst().compactMap { text -> Int? in
            guard let range = text.range(of: #""s":"#) else { return nil }
            return Int(text[range.upperBound...].prefix { $0.isNumber })
        }
        #expect(seqs == Array(0..<2000))
        // One bridge call per flush, at most 512 frames each: 512, 512, 512, 464.
        #expect(transport.flushes - before == 4)
    }

    @Test func aReconnectUsesTheRotatedLocalAppTokenAndClosesTheOldSocket() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-home-\(UUID().uuidString)")
        let tokenFile = AcpmuxLocalAppToken.path(home: home)
        try FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = String(repeating: "b2", count: 32)
        let second = String(repeating: "c3", count: 32)
        try (first + "\n").write(to: tokenFile, atomically: true, encoding: .utf8)
        let model = AgentPaneModel(host: FileTokenHost(url: server.url, home: home))
        let reply = await model.respond(to: .ready)
        // Neither token, nor the endpoint, is in the page's handshake.
        let encoded = String(describing: reply)
        #expect(!encoded.contains(first) && !encoded.contains("dash-token") && !encoded.contains("ws://"))
        let opened = try #require((await model.respond(to: .transportOpen))["value"] as? [String: Any])
        let one = try #require(opened["connection"] as? Int)
        _ = await model.respond(to: .transportSend(connection: one, frames: [Self.initialize]))
        // A second open of the same handshake is refused: its token was used.
        #expect(((await model.respond(to: .transportOpen))["error"] as? [String: Any])?["code"] as? String == "transport.no_connection")
        // The daemon restarted with a new token.
        try (second + "\n").write(to: tokenFile, atomically: true, encoding: .utf8)
        _ = await model.respond(to: .reconnect)
        let reopened = try #require((await model.respond(to: .transportOpen))["value"] as? [String: Any])
        let two = try #require(reopened["connection"] as? Int)
        #expect(two != one)
        _ = await model.respond(to: .transportSend(connection: two, frames: [Self.initialize]))
        #expect(await server.wait { $0.count == 2 && $0[1].frames.count == 1 && $0[0].closed })
        #expect(server.peers[0].frames.first?.contains(first) == true)
        #expect(server.peers[1].frames.first?.contains(second) == true)
        #expect(server.peers[1].frames.first?.contains(first) == false)
        // The old connection is gone for the page.
        #expect(((await model.respond(to: .transportSend(connection: one, frames: ["{}"])))["error"] as? [String: Any])?["code"] as? String
            == "transport.stale_connection")
    }

    @Test func aMissingOrMalformedTokenFileMeansNoToken() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-home-\(UUID().uuidString)")
        #expect(AcpmuxLocalAppToken.read(home: home) == nil)
        let file = AcpmuxLocalAppToken.path(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not-hex".write(to: file, atomically: true, encoding: .utf8)
        #expect(AcpmuxLocalAppToken.read(home: home) == nil)
        try "  \(Self.localApp)\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(AcpmuxLocalAppToken.read(home: home) == Self.localApp)
        #expect(!String(describing: AcpmuxConnection(url: URL(string: "ws://127.0.0.1:1/")!, dashboardToken: "dash", localAppToken: Self.localApp)).contains(Self.localApp))
    }

    @Test func aCwdOutsideTheWorkspaceRootsNeverReachesTheDaemon() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("transport-roots-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        let outside = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let transport = AgentPaneTransport()
        transport.roots = { [root.path] }
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(connection(server))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        let refused = #"{"jsonrpc":"2.0","id":5,"method":"session/new","params":{"cwd":"\#(outside.path)","mcpServers":[]}}"#
        #expect(await transport.send(connection: id, frames: [refused]) == .pathOutsideRoots)
        let allowed = #"{"jsonrpc":"2.0","id":6,"method":"_acpmux/prewarm","params":{"harness":"claude","cwd":"\#(root.path)"}}"#
        #expect(await transport.send(connection: id, frames: [allowed]) == nil)
        #expect(await server.wait { $0.first?.frames.count == 2 })
        let sent = try #require(server.peers.first?.frames.last)
        #expect(sent.contains("_acpmux/prewarm") && sent.contains(#""cwd":"\#(AcpmuxPathPolicy.canonical(root.path)!)""#))
        #expect(server.peers.first?.frames.contains { $0.contains("elsewhere") } == false)
        #expect(await eventually { events.flatMap(\.frames).contains { $0.contains(#""id":5"#) && $0.contains("transport.path_outside_roots") } })
    }
    /// Frames go to the socket in arrival order: a frame that waits for the disk check is never
    /// overtaken by a later one.
    @Test func aPageActionGoesOutAtOnceAndAWaitingFrameKeepsItsPlace() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = AgentPaneTransport()
        transport.roots = { [root.path] }
        transport.deliver = { _, done in done() }
        let id = try await transport.open(connection(server))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        var replies: [String] = []
        let cancel = #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}}"#
        // The frame's work runs off the main thread (0 ms on it per action), so the reply comes on a
        // later turn; the order is what holds.
        transport.submit(connection: id, frames: [cancel]) { _ in replies.append("first-cancel") }
        let new = #"{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"\#(root.path)","mcpServers":[]}}"#
        transport.submit(connection: id, frames: [new]) { _ in replies.append("new") }
        transport.submit(connection: id, frames: [cancel]) { _ in replies.append("second-cancel") }
        #expect(await server.wait { $0.first?.frames.count == 4 })
        let sent = server.peers.first?.frames ?? []
        #expect(sent.firstIndex { $0.contains("session/new") }! < sent.lastIndex { $0.contains("session/cancel") }!)
        #expect(await eventually { replies == ["first-cancel", "new", "second-cancel"] })
    }
}
