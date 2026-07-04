public import Foundation

/// A typed representation of the response returned by `/api/client-config`.
public struct ClientConfig: Decodable, Sendable, Equatable {
    /// Feature flag values keyed by PostHog feature flag key.
    public let featureFlags: [String: ClientConfigFlagValue]
    /// Feature flag payloads keyed by PostHog feature flag key.
    public let featureFlagPayloads: [String: ClientConfigJSONValue]
    /// Whether PostHog reported errors while evaluating flags.
    public let errorsWhileComputingFlags: Bool
    /// Optional upstream request id for diagnostics.
    public let requestId: String?

    /// Creates a client configuration value, primarily for tests and local composition.
    public init(
        featureFlags: [String: ClientConfigFlagValue],
        featureFlagPayloads: [String: ClientConfigJSONValue],
        errorsWhileComputingFlags: Bool,
        requestId: String? = nil
    ) {
        self.featureFlags = featureFlags
        self.featureFlagPayloads = featureFlagPayloads
        self.errorsWhileComputingFlags = errorsWhileComputingFlags
        self.requestId = requestId
    }

    /// Reads a declared flag through its typed resolver.
    public func value<Value>(_ flag: ClientConfigFlag<Value>) -> Value {
        flag.resolve(
            featureFlags[flag.key],
            featureFlagPayloads[flag.key]
        )
    }

    /// Decodes a declared payload into the caller's concrete type.
    public func payload<Value: Decodable & Sendable>(
        _ flag: ClientConfigPayloadFlag<Value>,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value? {
        guard let payload = featureFlagPayloads[flag.key] else {
            return flag.defaultValue
        }
        return try payload.decode(Value.self, decoder: decoder)
    }
}
