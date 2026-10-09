import CmuxNextApps
import CmuxNextDaemon
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
/// connection; a fake in tests).
@MainActor
struct AppsProviderLink {
    /// `apps-provider-register`: nil when accepted, else the refusal's code.
    var register: (_ families: [String]) async -> String?
    /// `apps-provider-result`.
    var answer: (_ requestID: UInt64, _ ok: Bool, _ body: AppJSON) async -> Void

    /// Over `daemon`'s current connection.
    static func daemon(_ daemon: DaemonService) -> AppsProviderLink {
        AppsProviderLink(register: { [weak daemon] families in
            guard let connection = daemon?.connection else { return "not_connected" }
            do {
                _ = try await connection.request(AppsProviderRegisterRequest(families: families))
                return nil
            } catch DaemonError.command(_, _, let code, _, _) {
                return code ?? "refused"
            } catch {
                return "failed"
            }
        }, answer: { [weak daemon] id, ok, body in
            guard let connection = daemon?.connection else { return }
            _ = try? await connection.request(AppsProviderResultRequest(requestID: id, ok: ok, body: body.daemonValue))
        })
    }
}

/// The Mac app as a provider of app op families (`apps-provider-register`):
/// it registers the families it has owner handlers for on every connection
/// that serves `apps-v1`, runs each routed call and answers it. A call the
/// supervisor cancels (deadline, revoke, host exit) is cancelled here and not
/// answered; a new connection cancels every call of the old one, so no
/// result goes to a dead connection. While an administrator turned apps off,
/// every call is answered `apps.disabled` and no handler runs. A
/// registration refused because another connection still holds a family
/// (`apps.provider.taken`) is tried again on the supervisor's next event.
@MainActor
final class AppsProviderChannel {
    private let link: AppsProviderLink
    private var capabilities: AppHostCapabilities?
    private var running: [UInt64: Task<Void, Never>] = [:]
    /// The connection epoch the families are registered on (set on success only).
    private var registeredEpoch: Int?
    /// A registration in flight, for this epoch.
    private var registeringEpoch: Int?
    /// The last refusal: only `apps.provider.taken` is tried again.
    private var refusal: String?
    private var epoch: Int?
    /// DisabledFeatures `apps`: the reason every call is refused with.
    var turnedOff: String? {
        didSet { if turnedOff != nil { cancelRunning() } }
    }
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "apps.provider")

    init(link: AppsProviderLink) {
        self.link = link
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
            cancelRunning()
            registeredEpoch = nil
            registeringEpoch = nil
            refusal = nil
        }
        self.epoch = epoch
        register()
    }

    /// Any supervisor event: `apps-provider-request` and `apps-provider-cancel`
    /// are taken (true); every event retries a registration a live
    /// connection held.
    func handle(name: String, payload: CmuxNextDaemon.JSONValue) -> Bool {
        if refusal == "apps.provider.taken" { register() }
        switch name {
        case "apps-provider-request":
            guard let call = AppsProviderCall(AppJSON(payload)) else { return true }
            run(call)
            return true
        case "apps-provider-cancel":
            if let id = AppJSON(payload)["request_id"]?.numberValue.flatMap({ UInt64(exactly: $0) }) {
                running.removeValue(forKey: id)?.cancel()
            }
            return true
        default:
            return false
        }
    }

    var isRegistered: Bool { registeredEpoch != nil && registeredEpoch == epoch }
    var runningCount: Int { running.count }

    private func cancelRunning() {
        for task in running.values { task.cancel() }
        running.removeAll()
    }

    private func register() {
        guard let capabilities, let epoch, registeredEpoch != epoch, registeringEpoch != epoch else { return }
        registeringEpoch = epoch
        let families = capabilities.families.sorted()
        // task-owner: one registration per connection; a new epoch drops its answer
        Task { [weak self, link] in
            let refused = await link.register(families)
            guard let self, self.epoch == epoch, registeringEpoch == epoch else { return }
            registeringEpoch = nil
            refusal = refused
            if let refused {
                logger.error("apps-provider-register refused: \(refused, privacy: .public)")
            } else {
                registeredEpoch = epoch
            }
        }
    }

    private func run(_ call: AppsProviderCall) {
        if let turnedOff {
            let (ok, body) = AppsProviderCall.disabledAnswer(turnedOff)
            // task-owner: one refusal answer while apps are turned off
            Task { [link] in await link.answer(call.requestID, ok, body) }
            return
        }
        guard let capabilities else { return }
        // task-owner: one routed app call; apps-provider-cancel, a new connection or the policy cancels it
        running[call.requestID] = Task { [weak self, link] in
            let (ok, body) = await call.answer(with: capabilities)
            guard !Task.isCancelled else { return }
            self?.running[call.requestID] = nil
            await link.answer(call.requestID, ok, body)
        }
    }
}
