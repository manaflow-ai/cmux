/// A typed request body for `/api/client-config`.
public struct ClientConfigRequest: Encodable, Sendable, Equatable {
    /// The PostHog distinct id for this evaluation.
    public let distinctId: String
    /// Optional context forwarded to PostHog by the web route.
    public let context: ClientConfigEvaluationContext
    /// Optional request labels sent as `X-Cmux-*` headers, never in the body,
    /// so the encoded payload the server parses stays unchanged.
    public var attribution: ClientConfigAttribution?

    private enum CodingKeys: String, CodingKey {
        case distinctId
        case context
    }

    /// Creates a request for feature-flag evaluation.
    public init(
        distinctId: String,
        context: ClientConfigEvaluationContext = .init(),
        attribution: ClientConfigAttribution? = nil
    ) {
        self.distinctId = distinctId
        self.context = context
        self.attribution = attribution
    }

    /// A copy of this request labeled with the trigger and poll cadence for
    /// one specific refresh. Requests without attribution stay unlabeled.
    public func labeled(
        refreshReason: ClientConfigAttribution.RefreshReason,
        pollIntervalSeconds: Int? = nil
    ) -> ClientConfigRequest {
        guard var attribution else { return self }
        attribution.refreshReason = refreshReason
        if let pollIntervalSeconds {
            attribution.pollIntervalSeconds = pollIntervalSeconds
        }
        var copy = self
        copy.attribution = attribution
        return copy
    }
}
