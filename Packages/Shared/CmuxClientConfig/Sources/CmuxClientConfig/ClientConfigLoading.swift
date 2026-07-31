/// Loads cmux client configuration from an injected backend.
public protocol ClientConfigLoading: Sendable {
    /// Fetches and decodes the current feature flags for a request.
    func load(_ request: ClientConfigRequest) async throws -> ClientConfig
}
