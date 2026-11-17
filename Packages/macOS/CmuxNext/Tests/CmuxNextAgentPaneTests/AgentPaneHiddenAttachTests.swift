import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A pane that is attached while nobody can see it (a restored tab after a restart, never shown)
/// gets its socket's hidden bound from the start. Before, the transport heard about visibility only
/// on a change: such a pane kept `paneHidden == false`, its socket used the visible queue (32 MiB,
/// 8192 frames) and its stream reached the hidden page as backlog pushes.
@Suite(.serialized)
@MainActor
struct AgentPaneHiddenAttachTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aPaneAttachedWhileHiddenHoldsItsStreamWithinTheHiddenBound() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hidden-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        // Made and never put in a window: nobody can see it, and no visibility change ever fires.
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let transport = view.model.transport
        #expect(transport.paneHidden, "a pane attached while hidden counted as visible")

        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        let socket = try #require(transport.socket)
        #expect(socket.isHidden, "the socket of a pane attached while hidden used the visible queue")
        _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
        // The daemon has the connection once it read the page's first frame.
        let connected = ContinuousClock.now + .seconds(10)
        while server.peers.first?.frames.isEmpty ?? true, ContinuousClock.now < connected {
            try await Task.sleep(for: .milliseconds(5))
        }
        let bound = transport.limits.hiddenQueuedFrames
        for seq in 1...(bound + 200) { server.push(AcpmuxStandInServer.benchFrame(seq), to: 0) }
        // Hidden, the socket sheds past its bound; with the visible queue it never does.
        let end = ContinuousClock.now + .seconds(10)
        while !socket.isShedding, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(socket.isShedding, "a pane attached while hidden kept \(socket.queuedFrames) frames past its hidden bound")
        #expect(socket.queuedFrames <= bound, "a pane attached while hidden held \(socket.queuedFrames) frames")
    }
}
