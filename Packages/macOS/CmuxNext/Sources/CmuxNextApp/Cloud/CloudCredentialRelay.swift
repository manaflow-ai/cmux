import CmuxNextDaemon
import Foundation

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
nonisolated struct CloudCredentialRelay: Sendable {
    /// The provider family this relay serves.
    static let family = "credential"
    static let relayOp = "credential.relay"
    static let sessionOp = "credential.session"
    /// The only app server the relay serves, and the only op family it
    /// sends: an install token with origin user counts as the person on the
    /// Worker (feed answers), so no other app and no other family may ever
    /// borrow it.
    static let app = "cmux/cloud"
    static let opPrefix = "cloud."
    /// `cloud.*` ops the relay never sends, whatever the app asks. The app
    /// server must never get a credential minted with this Mac's install
    /// token: `cloud.machine.link_token` is the link's dial credential, and
    /// only `cmux link` may mint it (decisions LINK-RESOLVE and
    /// LINK-TOKEN-OP; cloud-client-contract.md 1.7). This list is the
    /// guard; a Worker refusal of the request shape is not.
    static let refusedOps: Set<String> = ["cloud.machine.link_token"]
    /// The ops a Cloud VM sends about itself, with its own VM principal; a
    /// Mac never sends them.
    static let refusedPrefix = "cloud.vm."

    /// True when the relay may send `op` for the app server.
    static func mayRelay(_ op: String) -> Bool {
        op.hasPrefix(opPrefix) && !refusedOps.contains(op) && !op.hasPrefix(refusedPrefix)
    }

    /// POSTs `body` to `path` on the API Worker with `bearer`; returns the
    /// status and the body. Never logs the bearer.
    typealias Post = @Sendable (_ path: String, _ body: Data, _ bearer: String) async throws -> (status: Int, body: Data)

    struct Session: Sendable, Equatable {
        var signedIn: Bool
        var team: String?
    }

    /// One provider answer: `ok` and the ABI body.
    struct Answer: Sendable, Equatable {
        var ok: Bool
        var body: JSONValue
    }

    let post: Post
    /// A valid install token; throws when no user is signed in or the mint fails.
    let token: @Sendable () async throws -> String
    /// The Worker refused the token (401): the next ``token`` mints again.
    let invalidate: @Sendable () async -> Void
    let session: @Sendable () async -> Session

    /// Answers one provider call of the `credential` family.
    func answer(_ call: AppsProviderCall) async -> Answer {
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

    private func relay(_ params: JSONValue) async -> Answer {
        guard let op = params["op"]?.stringValue, !op.isEmpty else {
            return Self.failure("validation.invalid", "credential.relay needs an op")
        }
        guard op.hasPrefix(Self.opPrefix) else {
            return Self.failure("credential.op_refused", "the credential relay sends only \(Self.opPrefix)* ops")
        }
        guard Self.mayRelay(op) else {
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
