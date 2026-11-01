public import Foundation

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
public nonisolated struct CloudCredentialRelay: Sendable {
    /// The provider family this relay serves.
    public static let family = "credential"
    public static let relayOp = "credential.relay"
    public static let sessionOp = "credential.session"
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
    /// The current install generation. Link calls fence the answer to the
    /// same install/team that was signed in when the request began.
    let installID: @Sendable () async -> String?
    /// The Worker refused the token (401): the next ``token`` mints again.
    let invalidate: @Sendable () async -> Void
    let session: @Sendable () async -> Session
    /// The ops the app server may have sent (``bundledServedOps()`` in the app).
    let allowedOps: @Sendable () async -> Set<String>

    public init(post: @escaping Post, token: @escaping @Sendable () async throws -> String,
                invalidate: @escaping @Sendable () async -> Void, session: @escaping @Sendable () async -> Session,
                allowedOps: @escaping @Sendable () async -> Set<String>,
                installID: (@Sendable () async -> String?)? = nil) {
        self.post = post
        self.token = token
        self.installID = installID ?? { nil }
        self.invalidate = invalidate
        self.session = session
        self.allowedOps = allowedOps
    }

    /// Answers one provider call of the `credential` family.
    public func answer(_ call: AppsProviderCall) async -> Answer {
        guard call.app == Self.app else {
            return Self.failure("credential.app_refused", "only \(Self.app) may use the credential relay")
        }
        switch call.op {
        case Self.sessionOp:
            let state = await session()
            return Answer(ok: true, body: .object(["signed_in": .bool(state.signedIn), "team": state.team.map(JSONValue.string) ?? .null]))
        case Self.relayOp:
            return await relay(call.params)
        default:
            return Self.failure("operation.unsupported", "\(call.op) is not a credential op")
        }
    }

    /// Answers the private link transport. This path is deliberately separate
    /// from `answer`: it has no app/manifest input and is called only by the
    /// authenticated cmux-tui link socket. In particular, keeping
    /// `refusedOps` in the app-provider path means an app server can never
    /// acquire a dial token.
    func linkConnectInfo(host: String, expectedInstall: String? = nil) async -> Answer {
        await linkRequest(op: "cloud.machine.connect_info", params: .object(["host": .string(host)]), expectedInstall: expectedInstall)
    }

    func linkToken(host: String, services: [String], expectedInstall: String? = nil) async -> Answer {
        await linkRequest(op: "cloud.machine.link_token", params: .object([
            "host": .string(host),
            "services": .array(services.map(JSONValue.string)),
        ]), expectedInstall: expectedInstall)
    }

    private func linkRequest(op: String, params: JSONValue, expectedInstall: String? = nil) async -> Answer {
        let initialSession = await session()
        let initialInstall = await installID()
        guard initialSession.signedIn else { return Self.notSignedIn }
        guard let initialInstall, expectedInstall == nil || expectedInstall == initialInstall else { return Self.notSignedIn }
        guard await sameLinkGeneration(session: initialSession, install: initialInstall) else { return Self.notSignedIn }
        var envelope: [String: JSONValue] = ["op": .string(op), "params": params]
        if op == "cloud.machine.link_token" { envelope["origin"] = .string("cli") }
        guard let body = try? JSONEncoder().encode(JSONValue.object(envelope)) else { return Self.failure("validation.invalid", "link request is not JSON") }
        do {
            guard await sameLinkGeneration(session: initialSession, install: initialInstall) else { return Self.notSignedIn }
            let bearer = try await token()
            guard await sameLinkGeneration(session: initialSession, install: initialInstall) else { return Self.notSignedIn }
            var reply = try await post("v1/\(op.hasSuffix("connect_info") ? "read" : "ops")", body, bearer)
            if reply.status == 401 {
                await invalidate()
                guard await sameLinkGeneration(session: initialSession, install: initialInstall) else { return Self.notSignedIn }
                let retryBearer = try await token()
                guard await sameLinkGeneration(session: initialSession, install: initialInstall) else { return Self.notSignedIn }
                reply = try await post("v1/\(op.hasSuffix("connect_info") ? "read" : "ops")", body, retryBearer)
            }
            guard await sameLinkGeneration(session: initialSession, install: initialInstall) else { return Self.notSignedIn }
            return Self.answer(status: reply.status, body: reply.body)
        } catch {
            if await !session().signedIn { return Self.notSignedIn }
            return Self.failure("owner.unreachable", "the cmux API did not answer", retryable: true)
        }
    }

    private func sameLinkGeneration(session initial: Session, install initialInstall: String?) async -> Bool {
        let current = await session()
        guard current.signedIn, current.team == initial.team else { return false }
        guard let initialInstall else { return false }
        return await installID() == initialInstall
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
        guard await session().signedIn else { return Self.notSignedIn }
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
        do {
            var reply = try await post(path, body, try await token())
            if reply.status == 401 {
                // A stale token: mint once more, then the Worker's answer stands.
                await invalidate()
                reply = try await post(path, body, try await token())
            }
            return Self.answer(status: reply.status, body: reply.body)
        } catch {
            if await !session().signedIn { return Self.notSignedIn }
            return Self.failure("owner.unreachable", "the cmux API did not answer", retryable: true)
        }
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

    static func failure(_ code: String, _ message: String, retryable: Bool = false) -> Answer {
        Answer(ok: false, body: .object(["code": .string(code), "message": .string(message), "retryable": .bool(retryable)]))
    }
}
