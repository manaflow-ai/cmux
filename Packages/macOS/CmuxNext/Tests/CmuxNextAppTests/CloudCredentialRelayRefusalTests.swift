import CmuxNextApps
import CmuxNextCloud
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
        var bodies: [JSONValue] = []
        func add(_ path: String, _ body: Data) {
            let decoded = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
            let op = decoded["op"]?.stringValue ?? ""
            calls.append((path, op))
            bodies.append(decoded)
        }
    }

    /// The relay as the app builds it, with the bundled manifest's ops, or
    /// with `allowed` in their place.
    static func relay(_ sent: Sent, allowed: Set<String>? = nil, backendOrigin: String? = nil,
                      tokenTeam: @escaping @Sendable (String) -> String? = { _ in nil },
                      response: (@Sendable (JSONValue) -> JSONValue)? = nil) -> CloudCredentialRelay {
        CloudCredentialRelay(
            post: { path, body, _ in
                await sent.add(path, body)
                let request = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
                var reply: [String: JSONValue] = [
                    "op": request["op"] ?? .string(""),
                    "value": .object(["machines": .array([])]),
                    "revision": .string("1"),
                    "stream": .string("s"),
                ]
                if let key = request["idempotency_key"]?.stringValue {
                    reply["idempotency_key"] = .string(key)
                }
                let value = response?(request) ?? .object(reply)
                guard let data = try? JSONEncoder().encode(value) else { return (500, Data()) }
                return (200, data)
            },
            token: { "install-token-for-test" },
            invalidate: {},
            session: { CloudCredentialRelay.Session(signedIn: true, team: "team_test") },
            allowedOps: { if let allowed { allowed } else { await CloudCredentialRelay.bundledServedOps() } },
            backendOrigin: backendOrigin,
            tokenTeam: tokenTeam)
    }

    /// The daemon's provider line for a `credential.relay` of `op`.
    static func line(id: UInt64, op: String, key: String? = nil,
                     fence: [String: JSONValue] = [:]) throws -> Data {
        var params: [String: JSONValue] = ["op": .string(op), "params": .object(["host": .string("host_0123456789abcdef")])]
        if let key { params["idempotency_key"] = .string(key) }
        params.merge(fence) { _, newer in newer }
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

    /// The daemon's provider line for a `credential.carrier_socket` (the Cloud server's `relay.carrier`).
    static func carrierLine(id: UInt64, params: [String: JSONValue]) throws -> Data {
        let payload: JSONValue = .object([
            "event": .string(AppsProviderCall.eventName),
            "request_id": .number(Double(id)),
            "app": .string(CloudCredentialRelay.app),
            "op": .string(CloudCredentialRelay.carrierSocketOp),
            "params": .object(params),
        ])
        return try JSONEncoder().encode(payload)
    }

    /// A relay whose carrier answers `answer` and records the machines asked for; signed in or not.
    static func carrierRelay(_ sent: Sent, signedIn: Bool = true, asked: Asked,
                             answer: @escaping @Sendable (String) -> Result<String, CloudCredentialRelay.CarrierRefusal>) -> CloudCredentialRelay {
        CloudCredentialRelay(
            post: { path, body, _ in
                await sent.add(path, body)
                return (200, Data("{}".utf8))
            },
            token: { "install-token-for-test" },
            invalidate: {},
            session: { CloudCredentialRelay.Session(signedIn: signedIn, team: "team_test") },
            allowedOps: { [] },
            carrierSocket: { machine in
                await asked.add(machine)
                return answer(machine)
            })
    }

    actor Asked {
        var machines: [String] = []
        func add(_ machine: String) { machines.append(machine) }
    }

    /// The Cloud server's carrier ask answers only the path of the session's `carrier serve` socket; it
    /// never reaches the Worker and never carries a token.
    @Test func aCarrierAskAnswersTheSocketPathOnly() async throws {
        let (sent, asked) = (Sent(), Asked())
        let socket = "/tmp/cmux-501/cmux-link-0123456789ab.sock"
        let relay = Self.carrierRelay(sent, asked: asked) { _ in .success(socket) }
        let result = try await Self.answer(try Self.carrierLine(id: 11, params: ["machine": .string("vm_0123456789abcdefghij")]), relay: relay)
        #expect(result.requestID == 11)
        #expect(result.ok == true)
        #expect(result.body == .object(["value": .object(["socket": .string(socket)])]))
        #expect(await asked.machines == ["vm_0123456789abcdefghij"])
        #expect(await sent.calls.isEmpty)
    }

    /// A refusal keeps its carrier step code; a signed-out app and a line without a machine never ask.
    @Test func aCarrierRefusalKeepsItsCodeAndASignedOutAppNeverAsks() async throws {
        let (sent, asked) = (Sent(), Asked())
        let refused = Self.carrierRelay(sent, asked: asked) { _ in
            .failure(.init(code: "parked_timeout", message: "the machine's daemon never registered", retryable: true))
        }
        let result = try await Self.answer(try Self.carrierLine(id: 12, params: ["machine": .string("vm_1")]), relay: refused)
        #expect(result.ok == false)
        #expect(result.body["code"]?.stringValue == "parked_timeout")
        #expect(result.body["retryable"]?.boolValue == true)

        let signedOut = Self.carrierRelay(sent, signedIn: false, asked: asked) { _ in .success("/tmp/x.sock") }
        let out = try await Self.answer(try Self.carrierLine(id: 13, params: ["machine": .string("vm_1")]), relay: signedOut)
        #expect(out.body["code"]?.stringValue == "not_signed_in")
        let missing = try await Self.answer(try Self.carrierLine(id: 14, params: [:]), relay: refused)
        #expect(missing.body["code"]?.stringValue == "validation.invalid")
        #expect(await asked.machines == ["vm_1"], "only the first line asked")
        #expect(await sent.calls.isEmpty)
    }

    /// Cloud turned off by policy: neither a carrier ask nor a relayed op reaches the carrier or the
    /// Worker, so a Cloud app server cannot restart a stopped `carrier serve`; turned on, both run again.
    @Test func cloudTurnedOffByPolicyRefusesCarrierAndRelay() async throws {
        let (sent, asked) = (Sent(), Asked())
        let carrier = Self.carrierRelay(sent, asked: asked) { _ in .success("/tmp/x.sock") }
        let provider = CloudCredentialProvider(relay: carrier)
        provider.setTurnedOff(true)
        let off = try await Self.answer(try Self.carrierLine(id: 15, params: ["machine": .string("vm_1")]), relay: carrier)
        #expect(off.ok == false)
        #expect(off.body["code"]?.stringValue == "cmux.policy.turned_off")
        let relay = Self.relay(sent)
        relay.policy.set(turnedOff: true)
        let relayed = try await Self.answer(try Self.line(id: 16, op: "cloud.machine.connect_info"), relay: relay)
        #expect(relayed.body["code"]?.stringValue == "cmux.policy.turned_off")
        #expect(await asked.machines.isEmpty)
        #expect(await sent.calls.isEmpty)
        provider.setTurnedOff(false)
        let on = try await Self.answer(try Self.carrierLine(id: 17, params: ["machine": .string("vm_1")]), relay: carrier)
        #expect(on.ok == true)
        #expect(await asked.machines == ["vm_1"])
    }

    /// How many install-token mints a relay call started (the live relay's `session` mints for its team too).
    actor Mints {
        var count = 0
        func add() { count += 1 }
    }

    /// A relay whose `token` runs `mint` and whose `session` mints like the live one; `post` throws `postError` when set.
    static func mintingRelay(_ sent: Sent, _ mints: Mints, postError: URLError? = nil,
                             mint: @escaping @Sendable () async throws -> String) -> CloudCredentialRelay {
        CloudCredentialRelay(
            post: { path, body, _ in
                await sent.add(path, body)
                if let postError { throw postError }
                return (200, Data(#"{"op":"cloud.machine.list","value":{"machines":[]},"revision":"1","stream":"s"}"#.utf8))
            },
            token: { await mints.add(); return try await mint() },
            invalidate: {},
            session: {
                await mints.add()
                return CloudCredentialRelay.Session(signedIn: true, team: (try? await mint()).map { _ in "team_test" })
            },
            signedIn: { true },
            allowedOps: { await CloudCredentialRelay.bundledServedOps() })
    }

    /// One relayed op mints once: its signed-in check never mints (production's 30 s answer was two mints in a row).
    @Test func aRelayedOpMintsOnce() async throws {
        let (sent, mints) = (Sent(), Mints())
        let result = try await Self.answer(try Self.line(id: 20, op: "cloud.machine.list"),
                                           relay: Self.mintingRelay(sent, mints) { "install-token-for-test" })
        #expect(result.ok == true)
        #expect(await mints.count == 1)
        #expect(await sent.calls.count == 1)
    }

    @Test func aFencedMutationKeepsScopeLocalAndForwardsOnlyRevision() async throws {
        let sent = Sent()
        let relay = Self.relay(sent, backendOrigin: "https://cloud.example.com",
                               tokenTeam: { _ in "team_test" })
        let result = try await Self.answer(try Self.line(
            id: 24, op: "cloud.machine.start", key: "k-24",
            fence: ["expected_backend": .string("https://cloud.example.com/"),
                    "expected_team": .string("team_test"),
                    "expected_revision": .string("42")]), relay: relay)
        #expect(result.ok)
        let body = try #require((await sent.bodies).first)
        #expect(body["expected_backend"] == nil)
        #expect(body["expected_team"] == nil)
        #expect(body["expected_revision"]?.stringValue == "42")
        #expect(body["idempotency_key"]?.stringValue == "k-24")
    }

    @Test func aFencedMutationRejectsWrongOperationOrIdempotencyKey() async throws {
        let responses: [JSONValue] = [
            .object(["op": .string("cloud.machine.pause"), "idempotency_key": .string("k-29"), "value": .object([:])]),
            .object(["op": .string("cloud.machine.start"), "idempotency_key": .string("other"), "value": .object([:])]),
        ]
        for (offset, response) in responses.enumerated() {
            let sent = Sent()
            let relay = Self.relay(sent, backendOrigin: "https://cloud.example.com",
                                   tokenTeam: { _ in "team_test" }, response: { _ in response })
            let result = try await Self.answer(try Self.line(
                id: UInt64(29 + offset), op: "cloud.machine.start", key: "k-29",
                fence: ["expected_backend": .string("https://cloud.example.com"),
                        "expected_team": .string("team_test"),
                        "expected_revision": .string("1")]), relay: relay)
            #expect(result.body["code"]?.stringValue == "credential.response_invalid")
            #expect(await sent.calls.count == 1)
        }
    }

    @Test func wrongBackendOrTeamIsRefusedBeforeAWorkerPost() async throws {
        let wrongBackend = Sent()
        let backendRelay = Self.relay(wrongBackend, backendOrigin: "https://cloud.example.com",
                                      tokenTeam: { _ in "team_test" })
        let backendResult = try await Self.answer(try Self.line(
            id: 25, op: "cloud.machine.start", key: "k-25",
            fence: ["expected_backend": .string("https://other.example.com"),
                    "expected_team": .string("team_test"),
                    "expected_revision": .string("1")]), relay: backendRelay)
        #expect(backendResult.body["code"]?.stringValue == "credential.scope_refused")
        #expect(await wrongBackend.calls.isEmpty)

        let wrongTeam = Sent()
        let teamRelay = Self.relay(wrongTeam, backendOrigin: "https://cloud.example.com",
                                   tokenTeam: { _ in "team_test" })
        let teamResult = try await Self.answer(try Self.line(
            id: 26, op: "cloud.machine.start", key: "k-26",
            fence: ["expected_backend": .string("https://cloud.example.com"),
                    "expected_team": .string("team_other"),
                    "expected_revision": .string("1")]), relay: teamRelay)
        #expect(teamResult.body["code"]?.stringValue == "credential.scope_refused")
        #expect(await wrongTeam.calls.isEmpty)
    }

    @Test func incompleteOrMalformedFenceIsRefusedBeforeMintOrPost() async throws {
        let fences: [[String: JSONValue]] = [
            ["expected_revision": .string("1")],
            ["expected_backend": .string("https://cloud.example.com")],
            ["expected_backend": .string("https://cloud.example.com"),
             "expected_team": .string("team_test"),
             "expected_revision": .number(1)],
            ["expected_backend": .string("not-an-origin"),
             "expected_team": .string("team_test"),
             "expected_revision": .string("1")],
        ]
        for (offset, fence) in fences.enumerated() {
            let sent = Sent()
            let relay = Self.relay(sent, backendOrigin: "https://cloud.example.com", tokenTeam: { _ in "team_test" })
            let result = try await Self.answer(try Self.line(id: UInt64(27 + offset), op: "cloud.machine.start", key: "k-27", fence: fence), relay: relay)
            #expect(result.body["code"]?.stringValue == "credential.fence_invalid")
            #expect(await sent.calls.isEmpty)
        }
    }

    @Test func a401RemintRefusesWhenTheFreshTokenChangesTeam() async throws {
        actor Tokens {
            var values = ["old-token", "new-token"]
            func next() -> String { values.removeFirst() }
        }
        let tokens = Tokens()
        let sent = Sent()
        let relay = CloudCredentialRelay(
            post: { path, body, _ in
                await sent.add(path, body)
                return (await sent.calls.count == 1)
                    ? (401, Data(#"{"code":"auth.unauthenticated","message":"stale"}"#.utf8))
                    : (200, Data(#"{"op":"cloud.machine.start","idempotency_key":"k-28","value":{},"revision":"2"}"#.utf8))
            },
            token: { await tokens.next() },
            invalidate: {},
            session: { CloudCredentialRelay.Session(signedIn: true, team: "team_old") },
            allowedOps: { ["cloud.machine.start"] },
            backendOrigin: "https://cloud.example.com",
            tokenTeam: { $0 == "old-token" ? "team_old" : "team_new" })
        let result = try await Self.answer(try Self.line(
            id: 28, op: "cloud.machine.start", key: "k-28",
            fence: ["expected_backend": .string("https://cloud.example.com"),
                    "expected_team": .string("team_old"),
                    "expected_revision": .string("1")]), relay: relay)
        #expect(result.body["code"]?.stringValue == "credential.scope_refused")
        #expect(await sent.calls.count == 1, "the changed-team retry is refused before its POST")
    }

    /// A failed mint answers that the mint failed and why (here a URL timeout), not "the cmux API did not answer",
    /// and sends nothing to the Worker.
    @Test func aFailedMintNamesTheMintAndItsError() async throws {
        let (sent, mints) = (Sent(), Mints())
        let relay = Self.mintingRelay(sent, mints) { throw URLError(.timedOut) }
        let result = try await Self.answer(try Self.line(id: 21, op: "cloud.machine.list"), relay: relay)
        #expect(result.ok == false)
        #expect(result.body["code"]?.stringValue == "credential.mint_failed")
        let message = try #require(result.body["message"]?.stringValue)
        #expect(message.contains("install token") && message.contains("URLError -1001"), "\(message)")
        #expect(!message.contains("install-token-for-test"))
        #expect(await mints.count == 1)
        #expect(await sent.calls.isEmpty)
    }

    /// A POST with no answer names the path it sent and the URL error.
    @Test func aFailedPostNamesItsPathAndError() async throws {
        let (sent, mints) = (Sent(), Mints())
        let relay = Self.mintingRelay(sent, mints, postError: URLError(.notConnectedToInternet)) { "install-token-for-test" }
        let result = try await Self.answer(try Self.line(id: 22, op: "cloud.machine.list"), relay: relay)
        #expect(result.body["code"]?.stringValue == "owner.unreachable")
        let message = try #require(result.body["message"]?.stringValue)
        #expect(message.contains("POST /v1/read") && message.contains("URLError -1009"), "\(message)")
        #expect(!message.contains("install-token-for-test"))
    }

    /// A mint that outlasts the relay's deadline (one that ignores cancellation, as a shared in-flight mint does) still
    /// answers inside it, `owner.timed_out` naming the step, so the daemon's 30 s provider deadline never hits.
    @Test func aStuckMintAnswersInsideTheDeadlineNamingItsStep() async throws {
        let (sent, mints) = (Sent(), Mints())
        var relay = Self.mintingRelay(sent, mints) {
            // Ignores cancellation, as a waiter on a shared in-flight mint does: an unstructured task's value.
            await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
            return "install-token-for-test"
        }
        relay.deadline = .milliseconds(200)
        // The mint succeeds after 3 s, so an answer that waited for it would be a success, not owner.timed_out.
        let result = try await Self.answer(try Self.line(id: 23, op: "cloud.machine.list"), relay: relay)
        #expect(result.body["code"]?.stringValue == "owner.timed_out")
        #expect(result.body["retryable"]?.boolValue == true)
        let message = try #require(result.body["message"]?.stringValue)
        #expect(message.contains("minting the install token"), "\(message)")
        #expect(await sent.calls.isEmpty)
    }
}
