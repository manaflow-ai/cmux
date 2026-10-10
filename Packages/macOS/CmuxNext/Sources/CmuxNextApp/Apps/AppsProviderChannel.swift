import CmuxNextApps
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import os

/// One `apps-provider-request` from the app supervisor (app-op-routing.md):
/// an app's call to an op the daemon does not own, already checked against
/// the app's scopes, grants and gesture tokens. The Mac answers it with its
/// owner handler (``AppHostCapabilities``) and replies with
/// `apps-provider-result`.
nonisolated struct AppsProviderCall: Sendable, Equatable {
    var requestID: UInt64
    var app: String
    var op: String
    var params: AppJSON
    /// `user` inside a gesture, else `script` (the supervisor's stamp; any other value counts as `script`).
    var origin: String

    /// Reads the event; nil when a field is missing.
    init?(_ payload: AppJSON) {
        guard let id = payload["request_id"]?.numberValue.flatMap({ UInt64(exactly: $0) }), let app = payload["app"]?.stringValue,
              let op = payload["op"]?.stringValue else { return nil }
        requestID = id
        self.app = app
        self.op = op
        params = payload["params"] ?? .object([:])
        origin = payload["origin"]?.stringValue == "user" ? "user" : "script"
    }

    /// The `{ok, body}` of the answer: the handler's value, or the ABI error
    /// body `{code, message, retryable, details?}` (an op without a handler
    /// is `operation.unsupported`).
    func answer(with capabilities: AppHostCapabilities) async -> (ok: Bool, body: AppJSON) {
        do throws(AppHostCapabilityError) {
            let value = try await capabilities.handle(AppHostCapabilityRequest(app: app, op: op, params: params, origin: origin))
            return (true, value)
        } catch {
            return (false, Self.errorBody(code: error.code, message: error.message, retryable: error.retryable, details: error.details))
        }
    }

    /// The answer while an administrator turned apps off on this Mac.
    static func disabledAnswer(_ reason: String) -> (ok: Bool, body: AppJSON) {
        (false, errorBody(code: "apps.disabled", message: reason, retryable: false, details: nil))
    }

    static func errorBody(code: String, message: String, retryable: Bool, details: AppJSON?) -> AppJSON {
        var body: [String: AppJSON] = ["code": .string(code), "message": .string(message), "retryable": .bool(retryable)]
        if let details { body["details"] = details }
        return .object(body)
    }
}

/// How the provider channel reaches the supervisor (the local daemon's
/// connection; a fake in tests). A connection is an opaque object: a call is
/// answered on the connection it arrived on, never on a newer one.
@MainActor
struct AppsProviderLink {
    /// The current connection, if any.
    var connection: () -> AnyObject?
    /// `apps-provider-register` on `connection`: nil when accepted, else the
    /// refusal's code (`not_connected`, `timeout`, `failed` for transport errors).
    var register: (_ connection: AnyObject, _ families: [String]) async -> String?
    /// `apps-provider-result` on `connection`.
    var answer: (_ connection: AnyObject, _ requestID: UInt64, _ ok: Bool, _ body: AppJSON) async -> Void

    /// Over `daemon`'s connections.
    static func daemon(_ daemon: DaemonService) -> AppsProviderLink {
        AppsProviderLink(connection: { [weak daemon] in daemon?.connection }, register: { connection, families in
            guard let connection = connection as? DaemonConnection else { return "not_connected" }
            do {
                _ = try await connection.request(AppsProviderRegisterRequest(families: families))
                return nil
            } catch DaemonError.command(_, _, let code, _, _) {
                return code ?? "refused"
            } catch DaemonError.timedOut {
                return "timeout"
            } catch DaemonError.notConnected, DaemonError.connectionClosed, DaemonError.daemonShutdown {
                return "not_connected"
            } catch {
                return "failed"
            }
        }, answer: { connection, id, ok, body in
            guard let connection = connection as? DaemonConnection else { return }
            _ = try? await connection.request(AppsProviderResultRequest(requestID: id, ok: ok, body: body.daemonValue))
        })
    }
}

/// The Mac app as a provider of app op families (`apps-provider-register`):
/// it registers the families it has owner handlers for on every connection
/// that serves `apps-v1`, runs each routed call and answers it on the
/// connection the call arrived on. A call the supervisor cancels (deadline,
/// revoke, host exit) is cancelled here and not answered; a new connection
/// cancels every call of the old one. While an administrator turned apps
/// off, every call, a running one included, is answered `apps.disabled` and
/// no handler runs. A registration refused because another connection still
/// holds a family (`apps.provider.taken`) or by a transient failure is tried
/// again on the same connection with exponential backoff, one at a time.
@MainActor
final class AppsProviderChannel {
    /// Refusals tried again on the same connection.
    static let retried: Set<String> = ["apps.provider.taken", "failed", "not_connected", "timeout"]

    /// Spacing of registration retries: 0.5 s doubling, at most 30 s, jittered.
    nonisolated static let registerBackoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))

    private struct Running {
        var task: Task<Void, Never>
        var connection: AnyObject
    }

    private let link: AppsProviderLink
    private let backoff: Backoff
    private var capabilities: AppHostCapabilities?
    private var running: [UInt64: Running] = [:]
    /// The connection epoch the families are registered on (set on success only).
    private var registeredEpoch: Int?
    /// The registration in flight or waiting for its retry (one at a time).
    private var registering: Task<Void, Never>?
    private var epoch: Int?
    /// DisabledFeatures `apps`: the reason every call is refused with.
    var turnedOff: String? {
        didSet { if let turnedOff { answerRunningDisabled(turnedOff) } }
    }
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "apps.provider")

    init(link: AppsProviderLink, backoff: Backoff = AppsProviderChannel.registerBackoff) {
        self.link = link
        self.backoff = backoff
    }

    /// The owner handlers (when the control router exists).
    func attach(_ capabilities: AppHostCapabilities) {
        self.capabilities = capabilities
        register()
    }

    /// The connection that serves `apps-v1` now (nil: none). Another epoch is
    /// another connection: the old one's calls are cancelled and the
    /// families registered again.
    func connectionChanged(epoch: Int?) {
        if epoch != self.epoch {
            for call in running.values { call.task.cancel() }
            running.removeAll()
            registering?.cancel()
            registering = nil
            registeredEpoch = nil
        }
        self.epoch = epoch
        register()
    }

    /// `apps-provider-request` and `apps-provider-cancel` (true); other events are not the provider's.
    func handle(name: String, payload: CmuxNextDaemon.JSONValue) -> Bool {
        switch name {
        case "apps-provider-request":
            guard let call = AppsProviderCall(AppJSON(payload)) else { return true }
            run(call)
            return true
        case "apps-provider-cancel":
            if let id = AppJSON(payload)["request_id"]?.numberValue.flatMap({ UInt64(exactly: $0) }) {
                running.removeValue(forKey: id)?.task.cancel()
            }
            return true
        default:
            return false
        }
    }

    var isRegistered: Bool { registeredEpoch != nil && registeredEpoch == epoch }
    var runningCount: Int { running.count }

    /// The policy turned apps off: every running call ends with `apps.disabled`, on its own connection.
    private func answerRunningDisabled(_ reason: String) {
        let calls = running
        running.removeAll()
        let (ok, body) = AppsProviderCall.disabledAnswer(reason)
        for (id, call) in calls {
            call.task.cancel()
            logger.info("apps-provider-result \(id, privacy: .public) apps.disabled (policy ended a running call)")
            // task-owner: one refusal answer for a call the policy ended
            Task { [link] in await link.answer(call.connection, id, ok, body) }
        }
    }

    private func register() {
        guard let capabilities, let epoch, registeredEpoch != epoch, registering == nil else { return }
        let families = capabilities.families.sorted()
        // task-owner: the connection's registration with its retries; a new epoch cancels it
        registering = Task { [weak self, link, backoff, logger] in
            var backoff = backoff
            while let connection = link.connection() {
                guard let refused = await link.register(connection, families) else {
                    guard !Task.isCancelled, let self, self.epoch == epoch else { return }
                    registeredEpoch = epoch
                    registering = nil
                    return
                }
                guard AppsProviderChannel.retried.contains(refused) else {
                    logger.error("apps-provider-register refused: \(refused, privacy: .public); next connection tries again")
                    return
                }
                logger.info("apps-provider-register refused: \(refused, privacy: .public); retry \(backoff.attempt + 1) after backoff")
                // concurrency-allow: Backoff.wait is an async sleep after a refused registration, not a blocking wait.
                do { try await backoff.wait(owner: "AppsProviderChannel.register") } catch { return }
            }
        }
    }

    private func run(_ call: AppsProviderCall) {
        guard let connection = link.connection() else { return }
        if let turnedOff {
            let (ok, body) = AppsProviderCall.disabledAnswer(turnedOff)
            logger.info("apps-provider-result \(call.requestID, privacy: .public) \(call.op, privacy: .public) apps.disabled")
            // task-owner: one refusal answer while apps are turned off
            Task { [link] in await link.answer(connection, call.requestID, ok, body) }
            return
        }
        guard let capabilities else { return }
        // task-owner: one routed app call; apps-provider-cancel, a new connection or the policy cancels it
        let task = Task { [weak self, link] in
            let (ok, body) = await call.answer(with: capabilities)
            guard !Task.isCancelled else { return }
            self?.running[call.requestID] = nil
            await link.answer(connection, call.requestID, ok, body)
        }
        running[call.requestID] = Running(task: task, connection: connection)
    }
}
