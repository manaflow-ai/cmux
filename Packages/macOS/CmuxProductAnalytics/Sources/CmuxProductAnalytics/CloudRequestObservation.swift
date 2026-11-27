/// One finished Cloud VM API request, as the client's request telemetry saw it.
/// ``ProductAnalytics`` derives machine create, delete, attach and plan-limit
/// events from these, so no Cloud call site needs its own analytics.
public struct CloudRequestObservation: Sendable, Equatable {
    /// `GET`, `POST`, `DELETE`, ...
    public let method: String
    /// The normalized route, machine ids replaced by `{id}` (`/api/vm/{id}/attach-endpoint`).
    public let route: String
    public let success: Bool
    /// The machine-readable failure token, nil on success.
    public let errorCode: String?
    public let durationMs: Double

    /// Creates an observation.
    public init(method: String, route: String, success: Bool, errorCode: String?, durationMs: Double) {
        self.method = method.uppercased()
        self.route = route
        self.success = success
        self.errorCode = errorCode
        self.durationMs = durationMs
    }
}
