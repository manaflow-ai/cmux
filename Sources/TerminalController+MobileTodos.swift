import CmuxControlSocket
import Foundation

/// Mobile todo verbs adapted onto the existing control-socket todo coordinator.
extension TerminalController {
    /// Dispatches a mobile todo verb through the shared workspace-todo command path.
    func v2MobileTodoDispatch(method: String, params: [String: Any]) -> V2CallResult {
        guard let controlMethod = mobileTodoControlMethod(method) else {
            return .err(
                code: "method_not_found",
                message: "Unknown mobile todo method",
                data: ["method": method]
            )
        }
        guard case .object(var typedParams)? = JSONValue(foundationObject: params) else {
            return .err(code: "invalid_params", message: "Invalid todo parameters", data: nil)
        }
        if case .string("in_progress")? = typedParams["state"] {
            // Mobile uses snake_case while the established Mac todo wire is frozen as in-progress.
            typedParams["state"] = .string("in-progress")
        }
        let request = ControlRequest(id: .null, method: controlMethod, params: typedParams)
        guard let result = controlCommandCoordinator.handle(request) else {
            return .err(code: "internal", message: "Todo command was not handled", data: nil)
        }
        switch result {
        case .ok(let payload):
            return .ok(payload.foundationObject)
        case .err(let code, let message, let data):
            return .err(code: code, message: message, data: data?.foundationObject)
        }
    }

    /// Maps the mobile namespace onto the shared control-socket todo namespace.
    func mobileTodoControlMethod(_ method: String) -> String? {
        switch method {
        case "mobile.todo.add": "workspace.todo.add"
        case "mobile.todo.set_state": "workspace.todo.set_state"
        case "mobile.todo.edit": "workspace.todo.edit"
        case "mobile.todo.move": "workspace.todo.move"
        case "mobile.todo.remove": "workspace.todo.remove"
        case "mobile.todo.open": "workspace.todo.open"
        case "mobile.status.set": "workspace.status.set"
        case "mobile.status.cycle": "workspace.status.cycle"
        default: nil
        }
    }
}
