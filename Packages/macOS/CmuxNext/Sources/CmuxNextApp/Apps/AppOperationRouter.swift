import CmuxNextApps
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// DEV prototype: the App's `AppOperationSink` for the JavaScriptCore app
/// engine (plans/cmux-next/app-platform.md section 4). The engine already
/// checked the app's scopes. Routes:
/// - `action.run` / `action.list` through the control router in process,
///   so validation, targets, the work queue and the origin rule are the
///   control socket's (origin `script`, `user` inside a tap);
/// - `workspace.list`, `tab.list`, `agent.list`, `terminal.get` from the
///   published ControlSnapshot (off the main actor, like the socket's reads);
///   `tab.focus` as `action.run palette.goToTab` with the tab as target;
/// - `notification.list` from the daemon's notification ledger;
/// - `app.storage.*` to a per-app JSON file; `net.fetch` via URLSession
///   (hosts already limited to the app's `net:` scopes; credentials stripped);
/// - anything else `operation.unsupported`.
nonisolated final class AppOperationRouter: AppOperationSink, Sendable {
    let router: ControlRouter
    let storage: AppStorageStore
    let ledger: @Sendable () async throws -> [ListNotificationsRequest.Entry]
    let net = AppNetFetch()

    init(router: ControlRouter, storage: AppStorageStore, ledger: @escaping @Sendable () async throws -> [ListNotificationsRequest.Entry]) {
        self.router = router
        self.storage = storage
        self.ledger = ledger
    }

    func perform(_ request: AppOperationRequest) async -> Result<AppOperationResult, AppOperationError> {
        do {
            return .success(AppOperationResult(value: try await value(for: request)))
        } catch let error as AppOperationError {
            return .failure(error)
        } catch {
            return .failure(AppOperationError(code: "operation.failed", message: String(describing: error)))
        }
    }

    private func value(for request: AppOperationRequest) async throws -> AppJSON {
        let params = request.params
        switch request.op {
        case "action.run":
            guard let id = params["id"]?.stringValue else { throw AppOperationError(code: "invalid_params", message: "action.run needs id") }
            return try await control("action.run", ["action": .string(id), "args": (params["args"] ?? .object([:])).settingsValue], origin: request.origin)
        case "action.list":
            return try await control("action.list", [:], origin: request.origin)
        case "tab.focus":
            guard let tab = params["tab"]?.stringValue else { throw AppOperationError(code: "invalid_params", message: "tab.focus needs tab") }
            return try await control("action.run", ["action": "palette.goToTab", "target": ["kind": "tab", "id": .string(tab)]],
                                     origin: request.origin)
        case "workspace.list": return AppTopologyReads.workspaces(router.snapshots.current.topology)
        case "tab.list": return AppTopologyReads.tabs(router.snapshots.current.topology, workspace: params["workspace"]?.stringValue)
        case "agent.list": return AppTopologyReads.agents(router.snapshots.current.topology)
        case "terminal.get":
            guard let terminal = params["terminal"]?.stringValue,
                  let value = AppTopologyReads.terminal(router.snapshots.current.topology, id: terminal) else {
                throw AppOperationError(code: "not_found", message: "no such terminal")
            }
            return value
        case "notification.list":
            return .array(try await ledger().prefix(200).map(AppTopologyReads.notification))
        case "app.storage.get": return try await storage.get(app: request.app, key: key(params))
        case "app.storage.set": return try await storage.set(app: request.app, key: key(params), value: params["value"] ?? .null)
        case "app.storage.delete": return try await storage.delete(app: request.app, key: key(params))
        case "app.storage.keys": return try await storage.keys(app: request.app)
        case "net.fetch": return try await net.fetch(params)
        default: throw AppOperationError.unsupported(request.op)
        }
    }

    private func key(_ params: AppJSON) throws -> String {
        guard let key = params["key"]?.stringValue, !key.isEmpty, key.count <= 256 else {
            throw AppOperationError(code: "invalid_params", message: "storage keys are 1 to 256 characters")
        }
        return key
    }

    /// One control method in process, with the app op's origin.
    private func control(_ method: String, _ params: [String: CmuxNextSettings.JSONValue], origin: AppOperationOrigin) async throws -> AppJSON {
        var params = params
        params["origin"] = .string(origin.rawValue)
        switch await router.handle(ControlRequest(method: method, params: params), connection: .inProcess) {
        case .success(let value): return AppJSON(value)
        case .failure(let error):
            throw AppOperationError(code: error.code, message: error.message, details: error.data.map(AppJSON.init))
        }
    }
}

nonisolated extension AppJSON {
    /// Settings/control JSON to app JSON (same shape).
    init(_ value: CmuxNextSettings.JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let v): self = .bool(v)
        case .number(let v): self = .number(v)
        case .string(let v): self = .string(v)
        case .array(let v): self = .array(v.map(AppJSON.init))
        case .object(let v): self = .object(v.mapValues(AppJSON.init))
        }
    }

    var settingsValue: CmuxNextSettings.JSONValue {
        switch self {
        case .null: .null
        case .bool(let v): .bool(v)
        case .number(let v): .number(v)
        case .string(let v): .string(v)
        case .array(let v): .array(v.map(\.settingsValue))
        case .object(let v): .object(v.mapValues(\.settingsValue))
        }
    }
}
