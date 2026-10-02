import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// The checkpoint operations over the resource API: a mutation's key rides
/// in the request envelope and its `MutationResult` comes back whole; a
/// `get` by key keeps the key as a param; the daemon's identify says whether
/// it serves checkpoints.
@Suite(.timeLimit(.minutes(1))) struct GitCheckpointClientTests {
    /// The resource requests a fake daemon received, in order.
    final class Seen: Sendable {
        let requests = Mutex<[[String: JSONValue]]>([])

        var first: [String: JSONValue]? { requests.withLock { $0.first } }
    }

    /// Records each resource request in `seen` and answers it with `reply`
    /// (nothing when nil).
    private static func server(
        seen: Seen, identify: String = ConnectionTests.identify,
        _ reply: @escaping @Sendable (_ id: String) -> String?
    ) throws -> FakeDaemonServer {
        try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe":
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            default:
                guard request["protocol"]?.stringValue == "cmux.protocol/2" else { return [] }
                seen.requests.withLock { $0.append(request) }
                return reply(request["id"]?.stringValue ?? "").map { [$0] } ?? []
            }
        })
    }

    @Test func aMutationCarriesTheEnvelopeKeyAndReturnsTheMutationResult() async throws {
        let seen = Seen()
        let server = try Self.server(seen: seen) { id in
            #"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"value":{"checkpoint_id":"cp_1"},"generation":"g1","revision":"7","replayed":true}}"#
        }
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let reply = try await GitResourceClient(connection: connection).mutate(
            "git.checkpoint.pin",
            params: ["path": .string("/repo"), "checkpoint_id": .string("cp_1"), "pin_id": .string("user:1"), "reason": .string("manual")],
            idempotencyKey: "key-1")
        #expect(reply.value == .object(["checkpoint_id": .string("cp_1")]))
        #expect(reply.revision == "7")
        #expect(reply.replayed == true)
        let request = try #require(seen.first)
        #expect(request["operation"] == .string("git.checkpoint.pin"))
        #expect(request["idempotency_key"] == .string("key-1"))
        guard case .object(let params) = request["params"] else {
            Issue.record("no params in \(request)")
            return
        }
        #expect(params["idempotency_key"] == nil)
        #expect(params["path"] == .string("/repo"))
        #expect(params["pin_id"] == .string("user:1"))
        await connection.close()
    }

    /// `git.checkpoint.get` is a read: no envelope key, and the create's key
    /// it looks up is a param.
    @Test func aGetByKeyCarriesTheKeyAsAParam() async throws {
        let seen = Seen()
        let server = try Self.server(seen: seen) { id in
            #"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"checkpoint_id":"cp_1"}}"#
        }
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let result = try await GitResourceClient(connection: connection).read(
            "git.checkpoint.get", params: ["path": .string("/repo"), "idempotency_key": .string("key-1")])
        #expect(result == .object(["checkpoint_id": .string("cp_1")]))
        let request = try #require(seen.first)
        #expect(request["idempotency_key"] == nil)
        guard case .object(let params) = request["params"] else {
            Issue.record("no params in \(request)")
            return
        }
        #expect(params["idempotency_key"] == .string("key-1"))
        await connection.close()
    }

    /// A mutation the daemon received but never answered times out: its
    /// outcome is unknown, never a definite refusal.
    @Test func aSentMutationWithNoReplyTimesOut() async throws {
        let seen = Seen()
        let server = try Self.server(seen: seen) { _ in nil }
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        await #expect {
            try await GitResourceClient(connection: connection).mutate(
                "git.checkpoint.create", params: ["path": .string("/repo")], idempotencyKey: "key-1", timeout: .milliseconds(200))
        } throws: { error in
            guard case DaemonError.timedOut = error else { return false }
            return true
        }
        #expect(seen.first?["idempotency_key"] == .string("key-1"))
        await connection.close()
    }

    @Test func identifySaysWhetherTheDaemonServesCheckpoints() async throws {
        let serving = ConnectionTests.identify.replacingOccurrences(
            of: #""attach-initial-size""#, with: #""attach-initial-size","git-checkpoints-v1""#)
        for (identify, expected) in [(serving, true), (ConnectionTests.identify, false)] {
            let server = try Self.server(seen: Seen(), identify: identify) { _ in nil }
            let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
            try await connection.start()
            #expect(await connection.identity?.supports(DaemonCapabilities.shared.gitCheckpoints) == expected)
            await connection.close()
            server.stop()
        }
    }
}
