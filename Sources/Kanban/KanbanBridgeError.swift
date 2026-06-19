import Foundation

/// Errors surfaced across the Kanban web bridge.
///
/// Each case carries a stable ``code`` the webview can branch on, plus a
/// localized, user-facing ``errorDescription``. Mirrors
/// ``AgentSessionBridgeError`` so the JS reply envelope shape is identical.
enum KanbanBridgeError: LocalizedError {
    case invalidRequest
    case missingParameter(String)
    case unsupportedMethod(String)
    case invalidColumn(String)

    /// Stable machine-readable identifier sent to the webview.
    var code: String {
        switch self {
        case .invalidRequest:
            return "invalidRequest"
        case .missingParameter:
            return "missingParameter"
        case .unsupportedMethod:
            return "unsupportedMethod"
        case .invalidColumn:
            return "invalidColumn"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return String(
                localized: "kanban.bridge.error.invalidRequest",
                defaultValue: "Invalid board request."
            )
        case .missingParameter(let parameter):
            _ = parameter
            return String(
                localized: "kanban.bridge.error.missingParameter",
                defaultValue: "The request is incomplete."
            )
        case .unsupportedMethod(let method):
            _ = method
            return String(
                localized: "kanban.bridge.error.unsupportedMethod",
                defaultValue: "This action is not supported."
            )
        case .invalidColumn(let column):
            _ = column
            return String(
                localized: "kanban.bridge.error.invalidColumn",
                defaultValue: "Unknown board column."
            )
        }
    }
}
