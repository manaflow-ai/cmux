public import CMUXMobileCore

/// Resolves an active Iroh transport after account-scoped startup completes.
public protocol CmxIrohDeferredTransportProviding: Sendable {
    /// Builds a transport from the currently active account-scoped runtime.
    ///
    /// - Parameter request: The exact peer route and intended Mac binding.
    /// - Returns: A disconnected transport owned by the active runtime.
    /// - Throws: ``CmxIrohClientRuntimeError/inactive`` until startup completes,
    ///   or a route validation error.
    func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport
}
