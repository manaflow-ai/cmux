public import Foundation
import CmuxNextCompat
import os

/// The Mac side of the host credential relay (cx-wb5.63, slice B of
/// cx-wb5.57; cmux-tui-core `apps/relay.rs`): a first-party app server
/// (`cmux/cloud`) sends `relay.op` / `relay.session`; the supervisor routes
/// them to this app's `credential` provider family as
/// `credential.relay {op, params, idempotency_key?, origin?}` and
/// `credential.session {}`. The app calls the API Worker with its INSTALL
/// token (never the Stack bearer; chief decision 2026-10-08): a read goes
/// to `POST /v1/read`, a keyed op to `POST /v1/ops`. The Worker's answer
/// goes back unchanged as the provider ABI body; the server sees no
/// credential and the daemon never sees one.
///
/// `credential.carrier_socket {machine}` (the Cloud server's `relay.carrier`
/// line, first-party-apps/cloud/server/src/link/dial.rs) answers the path
/// of this app's own `cmux carrier serve` socket of a machine it has a
/// session of, started when it is not running: `{value: {socket}}`. The
/// person's credential stays in that child; the answer holds only the path
/// (the child's socket is 0600, in this user's private temporary folder). A
/// refusal is `{code, message, retryable}` with a `cmux carrier` step code
/// (``CarrierRefusal``).
public nonisolated struct CloudCredentialRelay: Sendable {
    /// The provider family this relay serves.
    public static let family = "credential"
    public static let relayOp = "credential.relay"
    public static let sessionOp = "credential.session"
    public static let carrierSocketOp = "credential.carrier_socket"
    /// The only app server the relay serves, and the only op family it
    /// sends: an install token with origin user counts as the person on the
    /// Worker (feed answers), so no other app and no other family may ever
    /// borrow it.
    public static let app = "cmux/cloud"
    static let opPrefix = "cloud."
    /// Ops the relay never sends, even when the app's manifest lists them.
    /// The app server must never get a credential minted with this Mac's
    /// install token: `cloud.machine.link_token` is the link's dial
    /// credential, and only `cmux link` may mint it (decisions LINK-RESOLVE
    /// and LINK-TOKEN-OP; cloud-client-contract.md 1.7).
    static let refusedOps: Set<String> = ["cloud.machine.link_token"]
    /// The ops a Cloud VM sends about itself, with its own VM principal; a
    /// Mac never sends them.
    static let refusedPrefix = "cloud.vm."

    /// True when the relay may send `op` for the app server: one of the ops
    /// the app's bundled manifest serves (`allowed`, an allow list: an op the
    /// manifest does not name is refused, so a new credential op never
    /// passes by default), a `cloud.*` op, and never a refused one.
    static func mayRelay(_ op: String, allowed: Set<String>) -> Bool {
        allowed.contains(op) && op.hasPrefix(opPrefix) && !refusedOps.contains(op)
            && !op.hasPrefix(refusedPrefix)
    }

    /// POSTs `body` to `path` on the API Worker with `bearer`; returns the
    /// status and the body. Never logs the bearer.
    public typealias Post = @Sendable (_ path: String, _ body: Data, _ bearer: String) async throws -> (status: Int, body: Data)

    public struct Session: Sendable, Equatable {
        public var signedIn: Bool
        public var team: String?

        public init(signedIn: Bool, team: String?) {
            self.signedIn = signedIn
            self.team = team
        }
    }

    /// One provider answer: `ok` and the ABI body.
    public struct Answer: Sendable, Equatable {
        public var ok: Bool
        public var body: JSONValue
    }

    let post: Post
    /// A valid install token; throws when no user is signed in or the mint fails.
    let token: @Sendable () async throws -> String
    /// The Worker refused the token (401): the next ``token`` mints again.
    let invalidate: @Sendable () async -> Void
    let session: @Sendable () async -> Session
    /// The ops the app server may have sent (``bundledServedOps()`` in the app).
    let allowedOps: @Sendable () async -> Set<String>
    /// This app's carrier socket of a machine (``carrierSocketOp``).
    let carrierSocket: CarrierSocket
    /// Whether an organization turned Cloud off (`DisabledFeatures`): then no op is relayed and no
    /// carrier socket is handed out, so a Cloud app server cannot start a carrier around the policy.
    public let policy = Policy()
    /// Whether a user is signed in, without minting (the live ``session`` mints for its team): the
    /// relay's own checks, so one relay call starts at most one mint.
    let signedIn: @Sendable () async -> Bool
    /// How long one ``relayOp`` call may take before it answers `owner.timed_out` naming its step:
    /// inside the daemon's 30 s provider deadline (cmux-tui-core `apps/relay.rs`), so the server hears
    /// why rather than "the cmux app did not answer in time".
    var deadline: Duration = .seconds(25)
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")

    /// ``policy``: set on the main actor by the app's policy, read by each call.
    public nonisolated final class Policy: Sendable {
        private let state = Mutex(false)
        public var turnedOff: Bool { state.withLock { $0 } }
        public func set(turnedOff: Bool) { state.withLock { $0 = turnedOff } }
    }

    /// Why the app has no carrier socket of a machine: a `cmux carrier` step code (`ticket`, `relay`,
    /// `parked_timeout`, `handshake`, `service_refused`, `bad_request`, `socket`), `cloud.machine.not_found`
    /// (no session of that machine) or `unavailable`. Never a credential.
    public struct CarrierRefusal: Error, Equatable, Sendable {
        public var code: String
        public var message: String
        public var retryable: Bool

        public init(code: String, message: String, retryable: Bool = false) {
            (self.code, self.message, self.retryable) = (code, message, retryable)
        }
    }

    /// The carrier socket path of `machine`, or why there is none.
    public typealias CarrierSocket = @Sendable (_ machine: String) async -> Result<String, CarrierRefusal>

    /// No carrier (a relay built without the app's Cloud sessions).
    public static let noCarrier: CarrierSocket = { _ in
        .failure(CarrierRefusal(code: "unavailable", message: "this cmux has no Cloud carrier"))
    }

    public init(post: @escaping Post, token: @escaping @Sendable () async throws -> String,
                invalidate: @escaping @Sendable () async -> Void, session: @escaping @Sendable () async -> Session,
                signedIn: (@Sendable () async -> Bool)? = nil,
                allowedOps: @escaping @Sendable () async -> Set<String>,
                carrierSocket: @escaping CarrierSocket = CloudCredentialRelay.noCarrier) {
        self.post = post
        self.token = token
        self.invalidate = invalidate
        self.session = session
        self.signedIn = signedIn ?? { await session().signedIn }
        self.allowedOps = allowedOps
        self.carrierSocket = carrierSocket
    }

    /// Answers one provider call of the `credential` family.
    public func answer(_ call: AppsProviderCall) async -> Answer {
        guard call.app == Self.app else {
            return Self.failure("credential.app_refused", "only \(Self.app) may use the credential relay")
        }
        if call.op != Self.sessionOp, policy.turnedOff { return Self.turnedOff }
        switch call.op {
        case Self.sessionOp:
            let state = await session()
            return Answer(ok: true, body: .object(["signed_in": .bool(state.signedIn), "team": state.team.map(JSONValue.string) ?? .null]))
        case Self.relayOp:
            return await relay(call.params)
        case Self.carrierSocketOp:
            return await carrier(call.params)
        default:
            return Self.failure("operation.unsupported", "\(call.op) is not a credential op")
        }
    }

    /// `credential.carrier_socket {machine}`: the path only, for a signed-in app.
    private func carrier(_ params: JSONValue) async -> Answer {
        guard let machine = params["machine"]?.stringValue, !machine.isEmpty else {
            return Self.failure("validation.invalid", "credential.carrier_socket needs a machine")
        }
        guard await signedIn() else { return Self.notSignedIn }
        switch await carrierSocket(machine) {
        case .success(let socket):
            return Answer(ok: true, body: .object(["value": .object(["socket": .string(socket)])]))
        case .failure(let refusal):
            return Self.failure(refusal.code, refusal.message, retryable: refusal.retryable)
        }
    }

    private func relay(_ params: JSONValue) async -> Answer {
        guard let op = params["op"]?.stringValue, !op.isEmpty else {
            return Self.failure("validation.invalid", "credential.relay needs an op")
        }
        guard op.hasPrefix(Self.opPrefix) else {
            return Self.failure("credential.op_refused", "the credential relay sends only \(Self.opPrefix)* ops")
        }
        guard Self.mayRelay(op, allowed: await allowedOps()) else {
            return Self.failure("credential.op_refused", "the credential relay never sends \(op)")
        }
        guard await signedIn() else { return Self.notSignedIn }
        let key = params["idempotency_key"]?.stringValue
        var envelope: [String: JSONValue] = ["op": .string(op), "params": params["params"] ?? .object([:])]
        let path: String
        if let key {
            path = "v1/ops"
            envelope["idempotency_key"] = .string(key)
            envelope["origin"] = .string(params["origin"]?.stringValue ?? "script")
        } else {
            path = "v1/read"
        }
        guard let body = try? JSONEncoder().encode(JSONValue.object(envelope)) else {
            return Self.failure("validation.invalid", "credential.relay params are not JSON")
        }
        let step = Step()
        let bound = deadline
        return await RelayDeadline.race(bound, timeout: {
            let message = "the credential relay gave up on \(op) after \(bound) while \(step.name)"
            Self.logger.error("credential relay: \(message, privacy: .public)")
            return Self.failure("owner.timed_out", message, retryable: true)
        }) { await send(op, path, body, step) }
    }

    /// One relayed op: a token (the held one or one mint; a second only after the Worker refused the
    /// first with 401), then the POST. A failed mint and a failed POST each answer and log what failed;
    /// neither carries the token.
    private func send(_ op: String, _ path: String, _ body: Data, _ step: Step) async -> Answer {
        do {
            var reply = try await post(path, body, try await mint(op, step))
            if reply.status == 401 {
                // A stale token: mint once more, then the Worker's answer stands.
                await invalidate()
                reply = try await post(path, body, try await mint(op, step))
            }
            return Self.answer(status: reply.status, body: reply.body)
        } catch let refused as MintRefused {
            return refused.answer
        } catch {
            if await !signedIn() { return Self.notSignedIn }
            let why = Self.describe(error)
            Self.logger.error("credential relay: \(op, privacy: .public): POST /\(path, privacy: .public) failed: \(why, privacy: .public)")
            return Self.failure("owner.unreachable", "the cmux API did not answer POST /\(path): \(why)", retryable: true)
        }
    }

    /// The install token, or the answer that names why none could be minted.
    private func mint(_ op: String, _ step: Step) async throws -> String {
        step.set("minting the install token")
        defer { step.set("waiting for the cmux API") }
        do {
            return try await token()
        } catch {
            if await !signedIn() { throw MintRefused(answer: Self.notSignedIn) }
            let why = Self.describe(error)
            Self.logger.error("credential relay: \(op, privacy: .public): install token mint failed: \(why, privacy: .public)")
            throw MintRefused(answer: Self.failure("credential.mint_failed", "this Mac could not mint its cmux install token: \(why)",
                                                   retryable: true))
        }
    }

    /// A failed mint, as the answer the app server gets.
    private struct MintRefused: Error { var answer: Answer }

    /// The step one relay call is in, for its timeout answer.
    private nonisolated final class Step: Sendable {
        private let state = Mutex("checking the op")
        var name: String { state.withLock { $0 } }
        func set(_ name: String) { state.withLock { $0 = name } }
    }

    /// What failed, for a log line and an answer: a URL error's code, else the error's own description
    /// (an install-auth error names its request, code or HTTP status). Never a token.
    static func describe(_ error: any Error) -> String {
        if let url = error as? URLError { return "URLError \(url.code.rawValue)" }
        if error is CancellationError { return "cancelled" }
        return String(describing: error)
    }

    /// Folds a Worker answer into the ABI body: `{ok: true, value,
    /// revision?, replayed?}` keeps `value`, `revision` and `replayed`; an
    /// `{ok: false, error}` answer gives its error as is; a non-200 answer
    /// its `{code, message}` (retryable on 503).
    static func answer(status: Int, body: Data) -> Answer {
        let reply = try? JSONDecoder().decode(JSONValue.self, from: body)
        guard status == 200 else {
            let code = reply?["code"]?.stringValue ?? "http_\(status)"
            let message = reply?["message"]?.stringValue ?? "the cmux API answered HTTP \(status)"
            return failure(code, message, retryable: status == 503)
        }
        guard let reply, case .object = reply else {
            return failure("owner.bad_reply", "the cmux API answered no JSON object", retryable: true)
        }
        // `/v1/ops` answers `{ok, value | error}`; `/v1/read` answers
        // `{op, value, revision, stream}` with no `ok`, or `{error}`.
        let ok = reply["ok"]?.boolValue ?? (reply["error"] == nil && reply["value"] != nil)
        guard ok else {
            guard case .object(var error)? = reply["error"], error["code"]?.stringValue != nil else {
                return failure("owner.bad_reply", "the cmux API refused without an error code", retryable: true)
            }
            if error["message"]?.stringValue == nil { error["message"] = .string("") }
            if error["retryable"]?.boolValue == nil { error["retryable"] = .bool(false) }
            return Answer(ok: false, body: .object(error))
        }
        var out: [String: JSONValue] = ["value": reply["value"] ?? .null]
        if let revision = reply["revision"], revision != .null { out["revision"] = revision.stringValue.map(JSONValue.string) ?? revision }
        if let replayed = reply["replayed"]?.boolValue { out["replayed"] = .bool(replayed) }
        return Answer(ok: true, body: .object(out))
    }

    static let notSignedIn = failure("not_signed_in", "sign in to cmux")
    static let turnedOff = failure("cmux.policy.turned_off", "your organization turned off cmux Cloud")

    static func failure(_ code: String, _ message: String, retryable: Bool = false) -> Answer {
        Answer(ok: false, body: .object(["code": .string(code), "message": .string(message), "retryable": .bool(retryable)]))
    }
}

/// ``CloudCredentialRelay``'s bound on one relay call: the caller is answered at `bound` even when the
/// work ignores cancellation (a mint shared through the install client's in-flight task does), and the
/// work is then cancelled, never awaited. A task group would wait for its cancelled child.
nonisolated final class RelayDeadline: Sendable {
    typealias Answer = CloudCredentialRelay.Answer
    private struct State {
        var continuation: CheckedContinuation<Answer, Never>?
        var job: Task<Void, Never>?
    }
    private let state = Mutex(State())

    static func race(_ bound: Duration, timeout: @escaping @Sendable () -> Answer,
                     _ work: @escaping @Sendable () async -> Answer) async -> Answer {
        let gate = RelayDeadline()
        return await withCheckedContinuation { continuation in
            gate.state.withLock { $0.continuation = continuation }
            // concurrency-allow: one-shot timer, cancelled when the work answers first.
            let timer = Task {
                // wakeup-allow: one-shot deadline of one relay call (stops at the bound or the answer)
                try? await Task.sleep(for: bound)
                guard !Task.isCancelled else { return }
                gate.finish(timeout())
            }
            // concurrency-allow: the race answers at the bound without awaiting this task; it is cancelled then.
            let job = Task {
                let answer = await work()
                timer.cancel()
                gate.finish(answer)
            }
            let finished = gate.state.withLock { state -> Bool in
                guard state.continuation != nil else { return true }
                state.job = job
                return false
            }
            if finished { job.cancel() }
        }
    }

    /// The first answer wins; a later one is dropped, and work still running is cancelled.
    private func finish(_ answer: Answer) {
        let taken = state.withLock { state -> (CheckedContinuation<Answer, Never>, Task<Void, Never>?)? in
            guard let continuation = state.continuation else { return nil }
            state.continuation = nil
            defer { state.job = nil }
            return (continuation, state.job)
        }
        guard let (continuation, job) = taken else { return }
        continuation.resume(returning: answer)
        job?.cancel()
    }
}
