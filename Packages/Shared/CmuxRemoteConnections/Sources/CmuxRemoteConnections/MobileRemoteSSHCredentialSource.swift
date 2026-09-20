/// Loads a credential after the coordinator accepts the handshake key.
public struct MobileRemoteSSHCredentialSource: Sendable {
    private let loader: @Sendable () async throws -> MobileRemoteCredentialMaterial?

    /// Creates an injected source without accessing storage.
    /// - Parameter load: Returns material or nil for an interactive/provider auth path.
    public init(load: @escaping @Sendable () async throws -> MobileRemoteCredentialMaterial?) {
        loader = load
    }

    /// Loads material, withholding a result if cancellation was observed.
    /// - Returns: The requested short-lived credential.
    /// - Throws: Cancellation or storage errors without exposing secret bytes.
    public func load() async throws -> MobileRemoteCredentialMaterial? {
        try Task.checkCancellation()
        let material = try await loader()
        try Task.checkCancellation()
        return material
    }
}
