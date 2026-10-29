/// A coarse failure class for a Cloud request, safe to aggregate on.
public enum CloudErrorClass: String, Sendable, CaseIterable {
    case planLimit = "plan_limit"
    case auth
    case network
    case server
    case client
    case cancelled

    /// Classifies a client error code: a server `error` token, `http_<status>`,
    /// or a transport failure kind.
    public init(errorCode: String) {
        if CloudPlanLimit(errorCode: errorCode) != nil {
            self = .planLimit
            return
        }
        switch errorCode {
        case "not_signed_in", "session_refresh_failed", "http_401", "http_403", "vm_access_revoked",
             "vm_owner_mismatch", "vm_bound_token_required":
            self = .auth
        case "backend_unreachable", "url_error":
            self = .network
        case "cancelled":
            self = .cancelled
        case "malformed_response", "unknown", "vm_error", "vm_cloud_service_unavailable":
            self = .server
        default:
            if errorCode.hasPrefix("http_5") {
                self = .server
            } else {
                self = .client
            }
        }
    }
}
