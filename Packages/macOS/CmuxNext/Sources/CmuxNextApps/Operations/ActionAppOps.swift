public import CmuxNextSettings

/// The `action.*` ops of apps (`action.run`, `action.list`), mapped onto the
/// control methods with the app call's origin (`user` inside a gesture, else
/// `script`). The supervisor already checked the scope, the action's agent
/// surface and the view-state token before it routed the call here.
/// The original mutation key reaches the shared action router unchanged;
/// operation params cannot replace it or the supervisor's origin.
public nonisolated struct ActionAppOps: AppHostCapabilityHandler {
    let control: @Sendable (_ method: String, _ params: [String: JSONValue], _ callerApp: String) async throws(AppHostCapabilityError) -> JSONValue

    /// - Parameter control: Runs one control method in process for the calling app.
    public init(control: @escaping @Sendable (_ method: String, _ params: [String: JSONValue], _ callerApp: String) async throws(AppHostCapabilityError) -> JSONValue) {
        self.control = control
    }

    public var families: Set<String> { ["action"] }

    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        let origin = JSONValue.string(request.origin)
        switch request.op {
        case "action.run":
            guard let id = request.params["id"]?.stringValue else { throw AppHostCapabilityError(code: "invalid_params", message: "action.run needs id") }
            var params: [String: JSONValue] = ["action": .string(id), "args": (request.params["args"] ?? .object([:])).settingsValue, "origin": origin]
            params["idempotency_key"] = request.idempotencyKey.map(JSONValue.string)
            return AppJSON(try await control("action.run", params, request.app))
        case "action.list":
            return AppJSON(try await control("action.list", ["origin": origin], request.app))
        default:
            throw .unsupported(request.op)
        }
    }
}
