import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The page's `_acpmux/status` is read natively from the connection's socket path (#27102). A path
/// no unix socket can have (past the 103-byte limit, or empty) trapped in Network.framework
/// (`NWEndpoint.unix`, SIGTRAP) and took the whole process down; it is now an unreachable daemon,
/// so the page gets "status unavailable". `AgentPaneSendPickedFolderPromptTests` hit it with a
/// socket under a temporary folder.
@Suite(.serialized)
@MainActor
struct AcpmuxStatusLongSocketPathTests {
    /// A socket path of `length` bytes under the temporary folder.
    static func path(length: Int) -> String {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/aslp-"
        return base + String(repeating: "s", count: max(1, length - base.utf8.count - ".sock".utf8.count)) + ".sock"
    }

    @Test(arguments: [104, 160])
    func aSocketPathPastTheLimitThrowsInsteadOfTrapping(length: Int) async {
        let socket = Self.path(length: length)
        #expect(socket.utf8.count > AcpmuxEnvironment.maxSocketPathBytes)
        await #expect(throws: AcpmuxStatusClient.Failure.self) {
            _ = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/status", deadline: .seconds(2))
        }
    }

    @Test func anEmptySocketPathThrowsInsteadOfTrapping() async {
        await #expect(throws: AcpmuxStatusClient.Failure.self) {
            _ = try await AcpmuxStatusClient.call(socketPath: "", method: "_acpmux/status", deadline: .seconds(2))
        }
    }

    @Test func aPathAtTheLimitStillMakesAnEndpoint() throws {
        let socket = Self.path(length: AcpmuxEnvironment.maxSocketPathBytes)
        #expect(socket.utf8.count == AcpmuxEnvironment.maxSocketPathBytes)
        _ = try AcpmuxStatusClient.unixEndpoint(socket)
    }

    /// The page's status request on a connection whose socket path is too long is answered with an
    /// error, and the process lives on.
    @Test(.timeLimit(.minutes(1)))
    func thePagesStatusOnALongSocketPathIsAnsweredWithAnError() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let socket = Self.path(length: 160)
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil,
                                                           socketPath: socket))
        defer { transport.close(connection: id) }
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/status","params":{}}"#]) == nil)
        let reply = await inbox.frame(containing: #""id":1"#)
        #expect(reply.contains("status unavailable"))
    }
}
