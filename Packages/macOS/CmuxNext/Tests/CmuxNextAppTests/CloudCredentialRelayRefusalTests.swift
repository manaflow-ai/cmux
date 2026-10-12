@testable import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The credential relay never mints a dial credential for an app server
/// (cx-rtipa M2b; decisions LINK-RESOLVE and LINK-TOKEN-OP). Each test sends
/// the line the daemon sends on the provider channel (`apps-provider-request`
/// of family `credential`), lets the app's provider answer it, and records
/// every request the relay sends to the API Worker. A refused op gets
/// `credential.op_refused` and sends nothing to the Worker; an allowed op
/// does reach it, so the recorder sees what the relay sends.
@MainActor
@Suite(.serialized)
struct CloudCredentialRelayRefusalTests {
    /// What the relay sent to the Worker: path and op name, never the bearer.
    actor Sent {
        var calls: [(path: String, op: String)] = []
        func add(_ path: String, _ body: Data) {
            let op = (try? JSONDecoder().decode(JSONValue.self, from: body))?["op"]?.stringValue ?? ""
            calls.append((path, op))
        }
    }

    static func relay(_ sent: Sent) -> CloudCredentialRelay {
        CloudCredentialRelay(
            post: { path, body, _ in
                await sent.add(path, body)
                return (200, Data(#"{"op":"cloud.machine.list","value":{"machines":[]},"revision":"1","stream":"s"}"#.utf8))
            },
            token: { "install-token-for-test" },
            invalidate: {},
            session: { CloudCredentialRelay.Session(signedIn: true, team: "team_test") })
    }

    /// The daemon's provider line for a `credential.relay` of `op`.
    static func line(id: UInt64, op: String, key: String? = nil) throws -> Data {
        var params: [String: JSONValue] = ["op": .string(op), "params": .object(["host": .string("host_0123456789abcdef")])]
        if let key { params["idempotency_key"] = .string(key) }
        let payload: JSONValue = .object([
            "event": .string(AppsProviderCall.eventName),
            "request_id": .number(Double(id)),
            "app": .string(CloudCredentialRelay.app),
            "origin": .string("script"),
            "op": .string(CloudCredentialRelay.relayOp),
            "params": .object(params),
        ])
        return try JSONEncoder().encode(payload)
    }

    /// Sends one provider line through the app's provider; returns its answer.
    static func answer(_ line: Data, relay: CloudCredentialRelay) async throws -> AppsProviderResultRequest {
        let provider = CloudCredentialProvider(relay: relay)
        let (results, sink) = AsyncStream.makeStream(of: AppsProviderResultRequest.self)
        provider.handle(DaemonEvent.decode(name: AppsProviderCall.eventName, line: line)) { result in
            sink.yield(result)
            sink.finish()
        }
        var iterator = results.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    @Test(arguments: [
        ("cloud.machine.link_token", nil as String?),
        ("cloud.machine.link_token", "k-1"),
        ("cloud.vm.status.report", nil),
        ("cloud.vm.self.get", nil),
    ])
    func aRefusedOpNeverReachesTheWorker(op: String, key: String?) async throws {
        let sent = Sent()
        let result = try await Self.answer(try Self.line(id: 7, op: op, key: key), relay: Self.relay(sent))
        #expect(result.requestID == 7)
        #expect(result.ok == false)
        #expect(result.body["code"]?.stringValue == "credential.op_refused")
        #expect(await sent.calls.isEmpty)
    }

    @Test func anAllowedOpReachesTheWorker() async throws {
        let sent = Sent()
        let result = try await Self.answer(try Self.line(id: 8, op: "cloud.machine.connect_info"), relay: Self.relay(sent))
        #expect(result.ok == true)
        let calls = await sent.calls
        #expect(calls.count == 1)
        #expect(calls.first?.path == "v1/read")
        #expect(calls.first?.op == "cloud.machine.connect_info")
    }
}
