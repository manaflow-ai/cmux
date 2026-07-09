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

    /// Maps a Codex app-server approval request method to the JSON `result`
    /// payload this permission mode replies with. Returns `nil` for an
    /// unsupported method so the caller can emit its app-localized error.
    func approvalReply(forServerMethod method: String, params: [String: Any]?) -> [String: Any]? {
        switch method {
        case "item/commandExecution/requestApproval":
            return ["decision": commandApprovalDecision]
        case "item/fileChange/requestApproval":
            return ["decision": fileChangeApprovalDecision]
        case "item/permissions/requestApproval":
            return [
                "permissions": grantedPermissions(from: params),
                "scope": "turn"
            ]
        case "execCommandApproval", "applyPatchApproval":
            return ["decision": legacyReviewDecision]
        default:
            return nil
        }
    }
}
