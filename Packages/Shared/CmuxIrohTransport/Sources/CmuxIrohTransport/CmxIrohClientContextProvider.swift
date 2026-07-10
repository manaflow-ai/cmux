public import CMUXMobileCore

/// Resolves current reachability policy and admission proof for an Iroh route.
public protocol CmxIrohClientContextProvider: CmxIrohPrivateFallbackValidating, Sendable {
    /// Resolves one same-account dial context at connection time.
    ///
    /// - Parameter request: The validated route and expected Mac device binding.
    /// - Returns: Current route tiers and an endpoint-bound credential.
    /// - Throws: A registry, account, expiry, or local policy error.
    func context(for request: CmxByteTransportRequest) async throws -> CmxIrohClientContext
}

public extension CmxIrohClientContextProvider {
    /// Generation-less providers cannot authorize a private fallback.
    func validatePrivateFallback(
        _: CmxIrohPrivateFallbackAuthorization
    ) async throws {
        throw CmxIrohPrivateFallbackValidationError.unavailable
    }
}
