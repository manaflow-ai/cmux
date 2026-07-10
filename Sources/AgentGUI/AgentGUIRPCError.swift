import Foundation

enum AgentGUIRPCError: Error {
    case invalidParams
    case unsupportedProtocol
    case notFound
    case bindingLost
    case inputQueueFull
    case processExited
    case sendRejected(detail: String)
    case internalError

    var code: String {
        switch self {
        case .invalidParams: "invalid_params"
        case .unsupportedProtocol: "unsupported_protocol"
        case .notFound: "not_found"
        case .bindingLost: "binding_lost"
        case .inputQueueFull: "input_queue_full"
        case .processExited: "process_exited"
        case .sendRejected: "send_rejected"
        case .internalError: "internal_error"
        }
    }

    var message: String {
        switch self {
        case .invalidParams: "Invalid GUI RPC parameters"
        case .unsupportedProtocol: "Unsupported GUI protocol"
        case .notFound: "GUI session not found"
        case .bindingLost: "GUI session binding lost"
        case .inputQueueFull: "GUI session input queue full"
        case .processExited: "GUI session process exited"
        case .sendRejected: "GUI send rejected"
        case .internalError: "GUI RPC failed"
        }
    }

    var data: Any? {
        switch self {
        case .sendRejected(let detail):
            ["detail": detail]
        case .invalidParams, .unsupportedProtocol, .notFound, .bindingLost, .inputQueueFull, .processExited, .internalError:
            nil
        }
    }

    static func fromInjectionFailure(_ result: AgentGUITerminalInjectionResult) -> AgentGUIRPCError {
        switch result {
        case .accepted:
            .internalError
        case .bindingLost:
            .bindingLost
        case .inputQueueFull:
            .inputQueueFull
        case .processExited:
            .processExited
        }
    }
}
