extension WorkstreamPayload {
    /// The immutable request identity of an actionable payload, if present.
    public var requestID: String? {
        switch self {
        case .permissionRequest(let id, _, _, _), .exitPlan(let id, _, _), .question(let id, _): id
        default: nil
        }
    }
}
