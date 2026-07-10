import Foundation

enum AgentGUIRPCError: Error {
    case invalidParams
    case unsupportedProtocol
    case notFound
    case internalError

    var code: String {
        switch self {
        case .invalidParams: "invalid_params"
        case .unsupportedProtocol: "unsupported_protocol"
        case .notFound: "not_found"
        case .internalError: "internal_error"
        }
    }

    var message: String {
        switch self {
        case .invalidParams: "Invalid GUI RPC parameters"
        case .unsupportedProtocol: "Unsupported GUI protocol"
        case .notFound: "GUI session not found"
        case .internalError: "GUI RPC failed"
        }
    }
}
