import Foundation
import Testing
@testable import CmuxNextDaemon

/// `git.diff` and `git.status` over the resource API (`cmux.protocol/2`): the
/// result comes back as JSON, and a structured resource error keeps the
/// session host's code, details and retryable flag for the agent pane.
@Suite(.timeLimit(.minutes(1))) struct GitResourceClientTests {
    /// Answers each resource request with `reply` built from its id.
    static func server(_ reply: @escaping @Sendable (_ operation: String, _ id: String) -> String) throws -> FakeDaemonServer {
        try FakeDaemonServer(handler: ConnectionTests.handshake { request, _ in
            guard request["protocol"]?.stringValue == "cmux.protocol/2" else { return [] }
            return [reply(request["operation"]?.stringValue ?? "", request["id"]?.stringValue ?? "")]
        })
    }

    @Test func aReadReturnsTheSessionHostsResult() async throws {
        let server = try Self.server { _, id in
            #"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"root":"/repo","files":[]}}"#
        }
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let result = try await GitResourceClient(connection: connection).read("git.status", params: ["path": .string("/repo")])
        #expect(result == .object(["root": .string("/repo"), "files": .array([])]))
        await connection.close()
    }

    /// The session host's error object is `{code, message, details,
    /// retryable}`; all four reach the caller.
    @Test func aStructuredErrorKeepsItsDetailsAndRetryable() async throws {
        let server = try Self.server { operation, id in
            if operation == "git.status" {
                return #"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":false,"error":{"code":"mutation.indeterminate","message":"git timed out","details":null,"retryable":true}}"#
            }
            return #"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":false,"error":{"code":"operation.failed","message":"not a git repository","details":{"path":"/repo","exit_code":128,"stderr":["fatal"]},"retryable":false}}"#
        }
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let client = GitResourceClient(connection: connection)
        let details = JSONValue.object(["path": .string("/repo"), "exit_code": .number(128), "stderr": .array([.string("fatal")])])
        await #expect(throws: DaemonError.command(
            cmd: "git.diff", message: "not a git repository", code: "operation.failed", details: details, retryable: false)) {
            try await client.read("git.diff", params: ["path": .string("/repo"), "scope": .string("staged")])
        }
        // A null `details` is no details; `retryable` still comes through.
        await #expect(throws: DaemonError.command(
            cmd: "git.status", message: "git timed out", code: "mutation.indeterminate", details: nil, retryable: true)) {
            try await client.read("git.status", params: ["path": .string("/repo")])
        }
        await connection.close()
    }

    /// A raw protocol error (a string, no structured object) has neither.
    @Test func aPlainErrorHasNoDetailsOrRetryable() async throws {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, id in
            [#"{"id":\#(id),"ok":false,"error":"unknown pane 99","error_code":"pane_not_found"}"#]
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        await #expect {
            try await connection.closePane(99)
        } throws: { error in
            guard case DaemonError.command(_, let message, let code, let details, let retryable) = error else { return false }
            return message == "unknown pane 99" && code == "pane_not_found" && details == nil && retryable == nil
        }
        await connection.close()
    }
}
