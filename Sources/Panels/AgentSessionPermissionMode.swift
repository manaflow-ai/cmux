import Foundation

enum AgentSessionPermissionMode: String {
    case standard = "default"
    case autoReview = "auto-review"
    case fullAccess = "full-access"
    case custom

    var codexTurnOverrides: [String: Any] {
        switch self {
        case .standard, .custom:
            return [
                "approvalPolicy": "never",
                "approvalsReviewer": NSNull(),
                "sandboxPolicy": NSNull()
            ]
        case .autoReview:
            return [
                "approvalPolicy": "on-request",
                "approvalsReviewer": "auto_review",
                "sandboxPolicy": NSNull()
            ]
        case .fullAccess:
            return [
                "approvalPolicy": "never",
                "approvalsReviewer": "user",
                "sandboxPolicy": ["type": "dangerFullAccess"]
            ]
        }
    }
}
