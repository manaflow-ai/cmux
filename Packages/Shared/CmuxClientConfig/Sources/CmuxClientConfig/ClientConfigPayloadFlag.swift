/// A declared feature-flag payload with a typed decoder target.
public struct ClientConfigPayloadFlag<Value: Decodable & Sendable>: Sendable {
    /// The PostHog feature flag key whose payload should be decoded.
    public let key: String
    /// The value returned when the API response does not include a payload.
    public let defaultValue: Value?

    /// Creates a payload declaration.
    public init(key: String, defaultValue: Value? = nil) {
        self.key = key
        self.defaultValue = defaultValue
    }
}
