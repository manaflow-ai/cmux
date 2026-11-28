public import CmuxNextDaemon
public import Foundation
import os
import CmuxNextCompat

/// How one create's idempotency key reaches the Cloud API.
///
/// The server keeps each key per caller: the Mac's install (the relay) and the person's session (direct) are two
/// callers, so a key first sent on one route is only ever sent again on that route. A key sent on the other route
/// would be a new create there, and a second machine.
public nonisolated enum CloudCreateRoute: String, Sendable, Equatable {
    /// `apps-run` on the local daemon, which sends the op with the Mac's install token: the server holds a money op
    /// from an install for the person's approval (``CloudAppOpFailure/approvalPending``), answered as the person.
    case relay
    /// `/v1/ops` straight from this app as the signed-in person (``CloudPersonCreate``): the server runs a create
    /// from a verified person in one call, with no hold.
    case direct

    /// The step a measured start marks for one call on this route (`machine.create.direct`, `machine.create.relay`):
    /// a part of the start's `machine` step (``CloudStartStepRecord``).
    public var step: String { "machine.create.\(rawValue)" }

    /// `ops`, each call marked as ``step`` of the measured start this task runs for; outside one it marks nothing.
    public func timed(_ ops: @escaping CloudAppOp) -> CloudAppOp {
        let step = self.step
        return { op, args, key, origin in
            let steps = await Self.clock()
            do {
                let answer = try await ops(op, args, key, origin)
                await steps?.done(step)
                return answer
            } catch {
                await steps?.done(step)
                throw error
            }
        }
    }

    @MainActor private static func clock() -> CloudStartSteps? { CloudStartStepRecord.current == nil ? nil : CloudStartSteps(logger: logger) }
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
}

extension CloudMachineRequest {
    /// The route a send with ``idempotencyKey`` takes. A key that went out once keeps its first route (``route``);
    /// one sent, approved or being answered before routes were kept went on the relay, the only route then. A fresh
    /// key takes the direct route only for `personsOwnCreate`: a plain `cloud.machine.create` that the person's own
    /// gesture in this app started (never an agent's, a script's, the CLI's or a socket's, nor an agent's card the
    /// person has not clicked), in a known `team`. Everything else is the relay, held for the person's approval.
    public func createRoute(personsOwnCreate: Bool, team: String) -> CloudCreateRoute {
        if let route { return route }
        if wasSent || approvedRequest != nil || answeringRequest != nil { return .relay }
        return personsOwnCreate && environment == nil && !team.isEmpty ? .direct : .relay
    }
}

/// A person's own create sent straight to the Cloud API's `/v1/ops` as the signed-in person
/// (``CloudCreateRoute/direct``), through the same session call that answers an approval
/// (`CloudApprovalAnswer.Call`), in the team the relay would pin (`x-cmux-team`). The person's
/// session never goes to the daemon, and nothing here logs it.
public nonisolated struct CloudPersonCreate {
    public nonisolated init() {}
    /// One POST of a JSON body to the API Worker as the signed-in person; returns the reply body.
    /// The same shape as `CloudApprovalAnswer.Call`.
    public typealias Call = @Sendable (_ path: String, _ body: Data) async throws -> Data

    /// The direct route could not take the create, and the op never ran: no usable session, the session refused
    /// (`auth.*`, a team the session is not in, a sign-in policy), or a server that does not know the op. The create
    /// goes on the relay with a new key, never this one.
    public struct Unavailable: Error, Equatable, Sendable, CustomStringConvertible {
        public var reason: String
        public init(reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    /// How long a session call waits for its answer: an approval's read or answer comes at once.
    public static let callTimeout = 15
    /// How long a direct create waits for its answer. The server answers a person's create once the provider made
    /// the machine, or after 25 s with the machine still `provisioning` (cmux-platform CloudCore `REQUEST_WAIT_MS`),
    /// so the wait is longer than that: at 15 s a create the provider took 15 s over timed out.
    public static let createTimeout = 40

    /// Whether a request may have reached the server before its last attempt: noted when `cmux cloud install-post`
    /// says it sent a keyed op again after a connection failure. A direct create reads it (``ops(_:after:)``): a
    /// refusal answered to its resend does not prove the first never ran.
    public final class Resends: Sendable {
        private let count = Mutex(0)
        public init() {}
        public func note() { count.withLock { $0 += 1 } }
        public var any: Bool { count.withLock { $0 > 0 } }
    }

    /// The ``Resends`` the calls made in this task note on.
    @TaskLocal public static var resends: Resends?

    /// The `/v1/ops` body: `{op, params, idempotency_key, origin}`.
    public static func body(op: String, params: JSONValue, key: String?, origin: AppsRunRequest.Origin) throws -> Data {
        var body: [String: JSONValue] = ["op": .string(op), "params": params, "origin": .string(origin.rawValue)]
        if let key { body["idempotency_key"] = .string(key) }
        return try JSONEncoder().encode(JSONValue.object(body))
    }

    /// The create as a ``CloudAppOp`` over `call` (the session call, pinned to the team), each call after `first` is
    /// done (the create's `user.ensure`: nothing holds a direct create, so its bind must find the user). A call that
    /// throws before anything went out (no session) is ``Unavailable``; a transport failure may have reached the
    /// server, so it is thrown as is and the key stays on this route.
    ///
    /// A call whose request was sent again after a connection failure (``Resends``) may have run
    /// the op on its first attempt, so a route refusal answered to the resend is no ``Unavailable`` either: the relay
    /// would send a new key, a second machine. It is ``indeterminate``, and a Retry sends the same key on this route.
    public static func ops(_ call: @escaping Call, after first: @escaping @Sendable () async -> Void) -> CloudAppOp {
        { op, args, key, origin in
            let sent = try Self.body(op: op, params: args, key: key, origin: origin)
            await first()
            let resends = Resends()
            let reply: Data
            do {
                // concurrency-allow: the async binding inside an async closure: a task is always current here, and it is unbound when the call returns
                reply = try await $resends.withValue(resends) { try await call("v1/ops", sent) }
            } catch let error where !(error is URLError) && !(error is CancellationError) && !resends.any {
                throw Unavailable(reason: "not_signed_in")
            }
            do {
                return try Self.answer(reply)
            } catch let refused as Unavailable where resends.any {
                throw CloudAppOpFailure(code: indeterminate, message: "the create may have reached the Cloud before it was refused (\(refused.reason))")
            }
        }
    }

    /// The answer of a direct create that may have run before its route refused a resend (``ops(_:after:)``): not a
    /// definitive refusal, so the key and its route stay for a Retry.
    public static let indeterminate = "cmux.cloud.indeterminate"

    /// The op's value from a `/v1/ops` reply; a refusal as the relay would answer it (`cmux.cloud.<reason>`, with its
    /// details), or ``Unavailable`` when the route itself refused before the op ran.
    public static func answer(_ data: Data) throws -> JSONValue {
        guard let reply = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = reply else {
            throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "the Cloud API answered no JSON object")
        }
        if reply["ok"]?.boolValue == true, let value = reply["value"] { return value }
        // An op's own refusal sits in `error`; the route's (authorization, an unknown op) is the reply itself.
        let error = reply["error"] ?? reply
        let code = error["code"]?.stringValue ?? "", message = error["message"]?.stringValue ?? ""
        if routeRefusal(code: code, message: message, ofRoute: reply["error"] == nil) { throw Unavailable(reason: code) }
        throw CloudAppOpFailure(code: wireCodes[code] ?? "cmux.cloud.upstream_error", message: message.isEmpty ? code : message,
                                details: error["details"])
    }

    /// Whether `code` (with `message`) says the route, not the op, refused: the session's authorization (only the
    /// route's own answer, `ofRoute`), or an op this server does not know (`unknown mutation`, `unknown op`), or one
    /// not live on it yet. None of them ran the op.
    static func routeRefusal(code: String, message: String, ofRoute: Bool) -> Bool {
        if ofRoute, ["auth.unauthenticated", "auth.forbidden", "team.not_member", "auth.sso_required", "client.too_old", "policy.denied"].contains(code) {
            return true
        }
        if code == "validation.invalid", message.hasPrefix("unknown mutation ") || message.hasPrefix("unknown op ") { return true }
        return ofRoute && code == "owner.unreachable" && message.hasSuffix(" is not available yet")
    }

    /// `cmux.wire/1` codes and the code the Cloud app server answers for each (first-party-apps/cloud/server
    /// `api/error.rs` `WIRE_CODES`), so a refusal reads the same on either route. Any other is `upstream_error`.
    static let wireCodes: [String: String] = [
        "auth.unauthenticated": "cmux.cloud.auth_required", "auth.forbidden": "cmux.cloud.forbidden",
        "auth.sso_required": "cmux.cloud.forbidden", "client.too_old": "cmux.cloud.forbidden", "policy.denied": "cmux.cloud.forbidden",
        "validation.invalid": "cmux.cloud.invalid_args", "selector.not_found": "cmux.cloud.not_found",
        "cloud.machine.not_found": "cmux.cloud.not_found", "cloud.snapshot.not_found": "cmux.cloud.not_found",
        "cloud.environment.not_found": "cmux.cloud.not_found", "cloud.environment.invalid": "cmux.cloud.environment_invalid",
        "cloud.environment.busy": "cmux.cloud.environment_busy", "cloud.environment.secrets_unavailable": "cmux.cloud.secrets_unavailable",
        "idempotency.conflict": "cmux.cloud.idempotency_conflict", "revision.conflict": "cmux.cloud.conflict",
        "mutation.indeterminate": "cmux.cloud.indeterminate", "owner.unreachable": "cmux.cloud.upstream_error",
        "cloud.plan.required": "cmux.cloud.plan_required", "cloud.quota.exceeded": "cmux.cloud.quota_exceeded",
        "cloud.quota.vm_limit": "cmux.cloud.vm_limit", "cloud.size.locked": "cmux.cloud.size_locked",
        "cloud.spend_cap.reached": "cmux.cloud.spend_cap_reached", "cloud.member_budget.reached": "cmux.cloud.member_budget_reached",
        "cloud.provider.unavailable": "cmux.cloud.provider_unavailable", "cloud.machine.not_bound": "cmux.cloud.not_bound",
        "cloud.machine.paused": "cmux.cloud.machine_paused", "cloud.migration.unavailable": "cmux.cloud.migration_unavailable",
        "cloud.machine.not_classic": "cmux.cloud.not_classic", "cloud.upgrade.failed": "cmux.cloud.upgrade_failed",
        "cloud.rate_limited": "cmux.cloud.rate_limited", "cloud.no_snapshot_configured": "cmux.cloud.no_snapshot_configured",
        "cloud.machine.not_running": "cmux.cloud.not_running", "cloud.machine.not_paused": "cmux.cloud.not_paused",
        "cloud.machine.busy": "cmux.cloud.machine_busy", "cloud.size.grow_only": "cmux.cloud.size_grow_only",
        "cloud.link.install_refused": "cmux.cloud.link_install_refused", "approval.pending": "cmux.cloud.approval_pending",
        "approval.denied": "cmux.cloud.approval_denied", "approval.expired": "cmux.cloud.approval_expired",
        "approval.too_many_pending": "cmux.cloud.approval_too_many_pending",
    ]
}
