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
            var body: [String: AppJSON] = ["code": .string(error.code), "message": .string(error.message), "retryable": .bool(error.retryable)]
            if let details = error.details { body["details"] = details }
            return (false, .object(body))
        }
    }
}

/// The Mac app as a provider of app op families (`apps-provider-register`):
/// it registers the families it has owner handlers for on every connection
/// that serves `apps-v1`, runs each routed call and answers it. A call the
/// supervisor cancels (deadline, revoke, host exit) is cancelled here and
/// not answered. Registration needs the verified cmux app connection; a
/// refusal is logged and the supervisor answers those calls
/// `provider.unavailable`.
@MainActor
final class AppsProviderChannel {
    private let daemon: DaemonService
    private var capabilities: AppHostCapabilities?
    private var running: [UInt64: Task<Void, Never>] = [:]
    /// The connection epoch the families were registered on.
    private var registeredEpoch: Int?
    private var epoch: Int?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "apps.provider")

    init(daemon: DaemonService) {
        self.daemon = daemon
    }

    /// The owner handlers (when the control router exists).
    func attach(_ capabilities: AppHostCapabilities) {
        self.capabilities = capabilities
        register()
    }

    /// A new connection that serves `apps-v1` (nil: none).
    func connectionChanged(epoch: Int?) {
        self.epoch = epoch
        if epoch == nil {
            // The supervisor already failed this connection's calls.
            for task in running.values { task.cancel() }
            running.removeAll()
            registeredEpoch = nil
        }
        register()
    }

    /// `apps-provider-request` and `apps-provider-cancel`; false for other events.
    func handle(name: String, payload: CmuxNextDaemon.JSONValue) -> Bool {
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

    private func register() {
        guard let capabilities, let epoch, registeredEpoch != epoch, let connection = daemon.connection else { return }
        registeredEpoch = epoch
        let families = capabilities.families.sorted()
        let logger = logger
        // task-owner: one registration per connection; the connection's end ends it
        Task {
            do {
                _ = try await connection.request(AppsProviderRegisterRequest(families: families))
            } catch {
                logger.error("apps-provider-register refused: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func run(_ call: AppsProviderCall) {
        guard let capabilities, let connection = daemon.connection else { return }
        // task-owner: one routed app call; apps-provider-cancel or the connection's end cancels it
        running[call.requestID] = Task { [weak self] in
            let (ok, body) = await call.answer(with: capabilities)
            guard !Task.isCancelled else { return }
            self?.running[call.requestID] = nil
            _ = try? await connection.request(AppsProviderResultRequest(requestID: call.requestID, ok: ok, body: body.daemonValue))
        }
    }
}
