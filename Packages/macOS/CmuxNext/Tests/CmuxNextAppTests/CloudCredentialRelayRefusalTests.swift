@testable import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The credential relay never mints a dial credential for an app server
/// (cx-rtipa M2b; decisions LINK-RESOLVE and LINK-TOKEN-OP). Each test sends
/// the line the daemon sends on the provider channel (`apps-provider-request`
/// of family `credential`), lets the app's provider answer it, and records
/// every request the relay sends to the API Worker. The relay sends only the
/// ops the bundled `cmux/cloud` manifest serves (an allow list) and never a
/// credential op, even one a manifest would list. A refused op gets
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

    /// The relay as the app builds it, with the bundled manifest's ops, or
    /// with `allowed` in their place.
    static func relay(_ sent: Sent, allowed: Set<String>? = nil) -> CloudCredentialRelay {
        CloudCredentialRelay(
            post: { path, body, _ in
                await sent.add(path, body)
                return (200, Data(#"{"op":"cloud.machine.list","value":{"machines":[]},"revision":"1","stream":"s"}"#.utf8))
            },
            token: { "install-token-for-test" },
            invalidate: {},
            session: { CloudCredentialRelay.Session(signedIn: true, team: "team_test") },
            allowedOps: { if let allowed { allowed } else { await CloudCredentialRelay.bundledServedOps() } },
            installID: { "install-test" })
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
        // A real Cloud op that the cmux/cloud manifest does not serve.
        ("cloud.shell.open", "k-2"),
    ])
    func aRefusedOpNeverReachesTheWorker(op: String, key: String?) async throws {
        let sent = Sent()
        let result = try await Self.answer(try Self.line(id: 7, op: op, key: key), relay: Self.relay(sent))
        #expect(result.requestID == 7)
        #expect(result.ok == false)
        #expect(result.body["code"]?.stringValue == "credential.op_refused")
        #expect(await sent.calls.isEmpty)
    }

    /// A credential op stays refused even when an allow list names it.
    @Test func aCredentialOpIsRefusedWhenAManifestListsIt() async throws {
        let sent = Sent()
        let relay = Self.relay(sent, allowed: ["cloud.machine.link_token", "cloud.vm.status.report"])
        for op in ["cloud.machine.link_token", "cloud.vm.status.report"] {
            let result = try await Self.answer(try Self.line(id: 9, op: op), relay: relay)
            #expect(result.body["code"]?.stringValue == "credential.op_refused", "\(op)")
        }
        #expect(await sent.calls.isEmpty)
    }

    /// The bundled manifest is found: the ops the server sends are allowed.
    @Test func theBundledManifestServesTheServersOps() async {
        let served = await CloudCredentialRelay.bundledServedOps()
        for op in ["cloud.machine.list", "cloud.machine.get", "cloud.machine.connect_info", "cloud.machine.start"] {
            #expect(served.contains(op), "\(op)")
        }
        #expect(!served.contains("cloud.machine.link_token"))
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

    /// The link-only carrier can request both halves of LINK-RESOLVE/LINK-TOKEN-OP,
    /// while the app-provider route above continues to refuse the token op.
    @Test func privateLinkRouteUsesReadAndFreshMutation() async throws {
        let sent = Sent()
        let relay = Self.relay(sent)
        #expect((await relay.linkConnectInfo(host: "host_0123456789abcdefghij")).ok)
        #expect((await relay.linkToken(host: "host_0123456789abcdefghij", services: ["daemon"])).ok)
        let calls = await sent.calls
        #expect(calls.map(\.path) == ["v1/read", "v1/ops"])
        #expect(calls.map(\.op) == ["cloud.machine.connect_info", "cloud.machine.link_token"])
    }

    @Test func privateLinkRouteDropsAnAnswerAfterInstallRotation() async throws {
        actor Generation {
            var install = "install-a"
            func current() -> String { install }
            func rotate() { install = "install-b" }
        }
        let generation = Generation()
        let relay = CloudCredentialRelay(
            post: { _, _, _ in
                await generation.rotate()
                return (200, Data(#"{"op":"cloud.machine.connect_info","value":{}}"#.utf8))
            },
            token: { "token-a" }, invalidate: {},
            session: { CloudCredentialRelay.Session(signedIn: true, team: "team_test") },
            allowedOps: { [] }, installID: { await generation.current() })
        let result = await relay.linkConnectInfo(host: "host_0123456789abcdefghij")
        #expect(!result.ok)
        #expect(result.body["code"]?.stringValue == "not_signed_in")
    }

    @Test func privateLinkRouteRejectsAnOldSocketGeneration() async {
        let relay = Self.relay(Sent())
        let result = await relay.linkConnectInfo(host: "host_0123456789abcdefghij", expectedInstall: "install-old")
        #expect(!result.ok)
        #expect(result.body["code"]?.stringValue == "not_signed_in")
    }

    @Test func privateLinkRouteDoesNotPostWhenInstallChangesDuringTokenMint() async {
        actor Generation {
            var install = "install-a"
            var posts = 0
            func current() -> String { install }
            func rotate() { install = "install-b" }
            func posted() { posts += 1 }
            func postCount() -> Int { posts }
        }
        let generation = Generation()
        let relay = CloudCredentialRelay(
            post: { _, _, _ in await generation.posted(); return (200, Data(#"{"value":{}}"#.utf8)) },
            token: { await generation.rotate(); return "token-a" }, invalidate: {},
            session: { CloudCredentialRelay.Session(signedIn: true, team: "team_test") },
            allowedOps: { [] }, installID: { await generation.current() })
        let result = await relay.linkConnectInfo(host: "host_0123456789abcdefghij")
        #expect(!result.ok)
        #expect(await generation.postCount() == 0)
    }

    @Test func credentialSocketRejectsUnknownFieldsAndFitsDarwinRuntimePath() throws {
        let unknown = Data(#"{"op":"connect_info","host":"host_0123456789abcdefghij","extra":true}"#.utf8)
        #expect(!CloudLinkLauncher.credentialRequestAcceptedForTesting(unknown))
        let runtime = URL(fileURLWithPath: "/var/folders/ab/0123456789abcdefghijklmnopqrst/T/")
        let path = CloudLinkLauncher.credentialSocketPath(runtimeBase: runtime)
        #expect(path.utf8.count < 104)
        #expect(path != CloudLinkLauncher.credentialSocketPath(runtimeBase: runtime))
    }
}
