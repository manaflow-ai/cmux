public import CMUXMobileCore

/// Resolves current reachability policy and admission proof for an Iroh route.
public protocol CmxIrohClientContextProvider: Sendable {
    /// Resolves one same-account dial context at connection time.
    ///
    /// - Parameter request: The validated route and expected Mac device binding.
    /// - Returns: Current route tiers and an endpoint-bound credential.
    /// - Throws: A registry, account, expiry, or local policy error.
    func context(for request: CmxByteTransportRequest) async throws -> CmxIrohClientContext
}
