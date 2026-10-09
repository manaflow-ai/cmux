@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Synchronization
import Testing

/// The Mac app's `credential` provider (cx-wb5.63): a fake supervisor sends
/// `apps-provider-request` events; the app answers each with the API
/// Worker's reply, sent with the install token, and never registers on a
/// connection the daemon did not verify as the cmux app.
@MainActor
struct CloudCredentialProviderTests {
    nonisolated final class Worker: Sendable {
        struct Call: Sendable, Equatable {
            var path: String
            var bearer: String
            var body: JSONValue
        }

        let calls = Mutex<[Call]>([])
        let replies: Mutex<[(Int, String)]>
        let tokens = Mutex<[String]>(["tok-1", "tok-2"])
        let invalidated = Mutex(0)
        let signedIn: Bool

        init(signedIn: Bool = true, replies: [(Int, String)]) {
            self.signedIn = signedIn
            self.replies = Mutex(replies)
        }

        var all: [Call] { calls.withLock { $0 } }

        var relay: CloudCredentialRelay {
            CloudCredentialRelay(
                post: { path, body, bearer in
                    let json = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
                    self.calls.withLock { $0.append(Call(path: path, bearer: bearer, body: json)) }
                    let (status, text) = self.replies.withLock { $0.isEmpty ? (500, "{}") : $0.removeFirst() }
                    return (status, Data(text.utf8))
                },
                token: { self.tokens.withLock { $0.first ?? "none" } },
                invalidate: {
                    self.invalidated.withLock { $0 += 1 }
                    self.tokens.withLock { if !$0.isEmpty { $0.removeFirst() } }
                },
                session: { CloudCredentialRelay.Session(signedIn: self.signedIn, team: "team_1") }
            )
        }
    }

    /// Collects the results the provider sends back to the daemon.
    nonisolated final class Results: Sendable {
        let stream: AsyncStream<AppsProviderResultRequest>
        let continuation: AsyncStream<AppsProviderResultRequest>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream()
        }

        var reply: CloudCredentialProvider.Reply { { [continuation] in continuation.yield($0) } }

        func next() async -> AppsProviderResultRequest? {
            for await result in stream { return result }
            return nil
        }
    }

    static func request(_ id: Int, op: String = "credential.relay", params: JSONValue) -> DaemonEvent {
        .unknown(name: "apps-provider-request", payload: .object([
            "request_id": .number(Double(id)), "app": .string("cmux/cloud"), "origin": .string("user"),
            "op": .string(op), "params": params, "deadline_ms": .number(10_000),
        ]))
    }

    @Test func theVerifiedAppRegistersTheCredentialFamily() async {
        let sent = Mutex<[AppsProviderRegisterRequest]>([])
        let registered = await CloudCredentialProvider.register(userOriginAllowed: true) { request in
            sent.withLock { $0.append(request) }
            return .object(["families": .array([.string("credential")])])
        }
        #expect(registered)
        #expect(sent.withLock { $0.map(\.families) } == [["credential"]])
    }

    @Test func aConnectionTheDaemonDidNotVerifyNeverRegisters() async {
        let sent = Mutex(0)
        let registered = await CloudCredentialProvider.register(userOriginAllowed: false) { _ in
            sent.withLock { $0 += 1 }
            return .null
        }
        #expect(!registered)
        #expect(sent.withLock { $0 } == 0)
    }

    @Test func aRefusedRegistrationIsNotRetried() async {
        let sent = Mutex(0)
        let registered = await CloudCredentialProvider.register(userOriginAllowed: true) { _ in
            sent.withLock { $0 += 1 }
            throw DaemonError.command(cmd: "apps-provider-register", message: "only the verified cmux app", code: "apps.provider.forbidden")
        }
        #expect(!registered)
        #expect(sent.withLock { $0 } == 1)
    }

    @Test func aReadGoesToV1ReadWithTheInstallTokenAndAnswersTheWorkerReply() async throws {
        let worker = Worker(replies: [(200, #"{"ok":true,"value":{"machines":[],"next_cursor":null},"revision":"7"}"#)])
        let provider = CloudCredentialProvider(relay: worker.relay)
        let results = Results()
        provider.handle(Self.request(4, params: .object(["op": .string("cloud.machine.list"), "params": .object([:])])), reply: results.reply)
        let result = try #require(await results.next())
        #expect(result.requestID == 4)
        #expect(result.ok)
        #expect(result.body == .object(["value": .object(["machines": .array([]), "next_cursor": .null]), "revision": .string("7")]))
        #expect(worker.all == [Worker.Call(path: "v1/read", bearer: "tok-1",
                                           body: .object(["op": .string("cloud.machine.list"), "params": .object([:])]))])
    }

    @Test func aKeyedOpGoesToV1OpsWithItsKeyAndOrigin() async throws {
        let worker = Worker(replies: [(200, #"{"ok":true,"value":{"machine":{"id":"vm_1"}},"replayed":true}"#)])
        let provider = CloudCredentialProvider(relay: worker.relay)
        let results = Results()
        let params: JSONValue = .object(["op": .string("cloud.machine.start"), "params": .object(["machine": .string("vm_1")]),
                                         "idempotency_key": .string("k1"), "origin": .string("user")])
        provider.handle(Self.request(5, params: params), reply: results.reply)
        let result = try #require(await results.next())
        #expect(result.ok)
        #expect(result.body == .object(["value": .object(["machine": .object(["id": .string("vm_1")])]), "replayed": .bool(true)]))
        #expect(worker.all.map(\.path) == ["v1/ops"])
        #expect(worker.all.first?.body == .object(["op": .string("cloud.machine.start"), "params": .object(["machine": .string("vm_1")]),
                                                   "idempotency_key": .string("k1"), "origin": .string("user")]))
    }

    /// A Worker refusal (here the G8 approval wait of a money op) goes back
    /// as is, details included, so the app server can show it and retry with
    /// the same key.
    @Test func aWorkerRefusalGoesBackUnchanged() async throws {
        let refusal = #"{"ok":false,"error":{"code":"approval.pending","message":"cloud.machine.create waits","retryable":true,"details":{"request":"apr_1","expires_at":9}}}"#
        let worker = Worker(replies: [(200, refusal)])
        let provider = CloudCredentialProvider(relay: worker.relay)
        let results = Results()
        let params: JSONValue = .object(["op": .string("cloud.machine.create"), "params": .object([:]),
                                         "idempotency_key": .string("k2"), "origin": .string("user")])
        provider.handle(Self.request(6, params: params), reply: results.reply)
        let result = try #require(await results.next())
        #expect(!result.ok)
        #expect(result.body == .object(["code": .string("approval.pending"), "message": .string("cloud.machine.create waits"),
                                        "retryable": .bool(true), "details": .object(["request": .string("apr_1"), "expires_at": .number(9)])]))
    }

    @Test func aStaleTokenMintsOnceMoreAndRetries() async throws {
        let worker = Worker(replies: [(401, #"{"code":"auth.invalid","message":"expired"}"#), (200, #"{"ok":true,"value":{}}"#)])
        let provider = CloudCredentialProvider(relay: worker.relay)
        let results = Results()
        provider.handle(Self.request(7, params: .object(["op": .string("cloud.plan.get")])), reply: results.reply)
        let result = try #require(await results.next())
        #expect(result.ok)
        #expect(worker.all.map(\.bearer) == ["tok-1", "tok-2"])
        #expect(worker.invalidated.withLock { $0 } == 1)
    }

    @Test func signedOutAnswersNotSignedInWithoutACall() async throws {
        let worker = Worker(signedIn: false, replies: [])
        let provider = CloudCredentialProvider(relay: worker.relay)
        let results = Results()
        provider.handle(Self.request(8, params: .object(["op": .string("cloud.machine.list")])), reply: results.reply)
        let result = try #require(await results.next())
        #expect(!result.ok)
        #expect(result.body["code"] == .string("not_signed_in"))
        #expect(worker.all.isEmpty)
    }

    @Test func theSessionOpAnswersSignInAndTeam() async throws {
        let worker = Worker(replies: [])
        let provider = CloudCredentialProvider(relay: worker.relay)
        let results = Results()
        provider.handle(Self.request(9, op: "credential.session", params: .object([:])), reply: results.reply)
        let result = try #require(await results.next())
        #expect(result.ok)
        #expect(result.body == .object(["signed_in": .bool(true), "team": .string("team_1")]))
        #expect(worker.all.isEmpty)
    }

    @Test func callsOfOtherFamiliesAreLeftAlone() {
        let worker = Worker(replies: [])
        let provider = CloudCredentialProvider(relay: worker.relay)
        provider.handle(Self.request(10, op: "fs.pick", params: .object([:])), reply: { _ in Issue.record("answered fs.pick") })
        #expect(provider.inFlight == 0)
    }

    @Test func aNonOkHTTPAnswerIsItsCodeAndRetryableOn503() {
        let busy = CloudCredentialRelay.answer(status: 503, body: Data(#"{"code":"owner.busy","message":"later"}"#.utf8))
        #expect(busy == CloudCredentialRelay.Answer(ok: false, body: .object(["code": .string("owner.busy"), "message": .string("later"), "retryable": .bool(true)])))
        let forbidden = CloudCredentialRelay.answer(status: 403, body: Data(#"{"code":"auth.forbidden","message":"no"}"#.utf8))
        #expect(forbidden.body["retryable"] == .bool(false))
    }
}
