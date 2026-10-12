import CmuxNextApps
import CmuxNextControl
import CmuxNextSettings
import Foundation

nonisolated extension ControlRouter {
    /// Runs one control method in process for a Mac-side app op (the
    /// CodeRouter app's and page's ops, `action.*`): validation, targets, the
    /// work queue and the origin rule are the control socket's.
    func appControl(_ method: String, _ params: [String: JSONValue]) async throws(AppHostCapabilityError) -> JSONValue {
        switch await handle(ControlRequest(method: method, params: params), connection: .inProcess) {
        case .success(let value): return value
        case .failure(let error):
            throw AppHostCapabilityError(code: error.code, message: error.message, details: error.data.map(AppJSON.init))
        }
    }
}

/// The `action.*` ops of apps (`action.run`, `action.list`), mapped onto the
/// control methods with the app call's origin (`user` inside a gesture, else
/// `script`). The supervisor already checked the scope, the action's agent
/// surface and the view-state token before it routed the call here.
nonisolated struct ActionAppOps: AppHostCapabilityHandler {
    let control: @Sendable (_ method: String, _ params: [String: JSONValue]) async throws(AppHostCapabilityError) -> JSONValue

    var families: Set<String> { ["action"] }

    func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        let origin = JSONValue.string(request.origin)
        switch request.op {
        case "action.run":
            guard let id = request.params["id"]?.stringValue else {
                throw AppHostCapabilityError(code: "invalid_params", message: "action.run needs id")
            }
            return AppJSON(try await control("action.run", ["action": .string(id), "args": (request.params["args"] ?? .object([:])).settingsValue,
                                                            "origin": origin]))
        case "action.list":
            return AppJSON(try await control("action.list", ["origin": origin]))
        default:
            throw .unsupported(request.op)
        }
    }
}
