/// How one permission request ended, as the agent gets it.
public nonisolated struct PermissionOutcome: Sendable, Equatable {
    /// The result.
    public enum Result: String, Sendable, Equatable {
        /// The person continued and the grant landed.
        case granted
        /// The grant was already on: no card showed.
        case alreadyGranted = "already_granted"
        /// The person pressed Deny.
        case denied
        /// Nobody answered before the request's timeout.
        case timedOut = "timed_out"
        /// The agent or cmux withdrew the request.
        case cancelled
        /// This build cannot grant it (for example, no signed Computer Use helper).
        case unavailable

        /// The error code the agent sees, nil when the grant is on.
        public var errorCode: String? {
            switch self {
            case .granted, .alreadyGranted: nil
            case .denied: "permission_denied"
            case .timedOut: "permission_timed_out"
            case .cancelled: "permission_cancelled"
            case .unavailable: "permission_unavailable"
            }
        }
    }

    public var kind: PermissionKind
    public var result: Result
    /// The request's id (`perm_…`); nil when no card showed.
    public var requestID: String?
    /// The reason check the card showed.
    public var reasonCheck: PermissionReasonCheck.Verdict

    public init(kind: PermissionKind, result: Result, requestID: String?, reasonCheck: PermissionReasonCheck.Verdict) {
        self.kind = kind
        self.result = result
        self.requestID = requestID
        self.reasonCheck = reasonCheck
    }
}
