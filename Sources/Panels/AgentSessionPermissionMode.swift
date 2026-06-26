import Foundation

enum AgentSessionPermissionMode: String {
    case standard = "default"
    case autoReview = "auto-review"
    case fullAccess = "full-access"
    case custom

    var codexTurnOverrides: [String: Any] {
        switch self {
        case .standard:
            return [
                "approvalPolicy": "never",
                "approvalsReviewer": NSNull(),
                "sandboxPolicy": NSNull()
            ]
        case .custom:
            return [:]
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

extension AgentSessionPermissionMode {
    var commandApprovalDecision: String {
        switch self {
        case .fullAccess:
            return "acceptForSession"
        case .standard, .autoReview, .custom:
            return "decline"
        }
    }

    var fileChangeApprovalDecision: String {
        switch self {
        case .fullAccess:
            return "acceptForSession"
        case .standard, .autoReview, .custom:
            return "decline"
        }
    }

    var legacyReviewDecision: String {
        switch self {
        case .fullAccess:
            return "approved_for_session"
        case .standard, .autoReview, .custom:
            return "denied"
        }
    }

    func grantedPermissions(from params: [String: Any]?) -> [String: Any] {
        guard self == .fullAccess else {
            return [:]
        }
        return params?["permissions"] as? [String: Any] ?? [:]
    }
}
