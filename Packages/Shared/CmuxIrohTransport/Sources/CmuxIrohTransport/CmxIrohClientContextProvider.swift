public import CMUXMobileCore

/// Resolves current reachability policy and admission proof for an Iroh route.
public protocol CmxIrohClientContextProvider: CmxIrohPrivateFallbackValidating, Sendable {
    /// Resolves one same-account dial context at connection time.
    ///
    /// - Parameter request: The validated route and expected Mac device binding.
    /// - Returns: Current route tiers and an endpoint-bound credential.
    /// - Throws: A registry, account, expiry, or local policy error.
    func context(for request: CmxByteTransportRequest) async throws -> CmxIrohClientContext

    /// Refreshes generation-scoped private reachability after public dialing fails.
    func contextWithPrivateFallback(
        for request: CmxByteTransportRequest,
        basedOn context: CmxIrohClientContext
    ) async throws -> CmxIrohClientContext

    /// Records one terminal dial failure so the provider can invalidate any
    /// reusable discovery state before the next attempt for the same peer.
    ///
    /// - Parameters:
    ///   - request: The exact peer intent whose dial failed.
    ///   - dialPlan: The plan the failed dial used.
    ///   - failure: The bounded classification of the dial error.
    func noteDialFailure(
        for request: CmxByteTransportRequest,
        dialPlan: CmxIrohDialPlan,
        failure: DiagnosticFailureKind
    ) async
}

public extension CmxIrohClientContextProvider {
    /// Providers without a dynamic private source preserve the initial context.
    func contextWithPrivateFallback(
        for _: CmxByteTransportRequest,
        basedOn context: CmxIrohClientContext
    ) async throws -> CmxIrohClientContext {
        context
    }

    /// Generation-less providers cannot authorize a private fallback.
    func validatePrivateFallback(
        _: CmxIrohPrivateFallbackAuthorization
    ) async throws {
        throw CmxIrohPrivateFallbackValidationError.unavailable
    }

    /// Providers without reusable discovery state ignore dial outcomes.
    func noteDialFailure(
        for _: CmxByteTransportRequest,
        dialPlan _: CmxIrohDialPlan,
        failure _: DiagnosticFailureKind
    ) async {}
}
