/// A typed request body for `/api/client-config`.
public struct ClientConfigRequest: Encodable, Sendable, Equatable {
    /// The PostHog distinct id for this evaluation.
    public let distinctId: String
    /// Optional context forwarded to PostHog by the web route.
    public let context: ClientConfigEvaluationContext

    /// Creates a request for feature-flag evaluation.
    public init(distinctId: String, context: ClientConfigEvaluationContext = .init()) {
        self.distinctId = distinctId
        self.context = context
    }
}
