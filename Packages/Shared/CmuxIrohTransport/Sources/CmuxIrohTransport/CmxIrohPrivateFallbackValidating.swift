/// Revalidates an admitted private-network fallback immediately before dial.
public protocol CmxIrohPrivateFallbackValidating: Sendable {
    /// Confirms the admitted generation, profiles, and hint freshness.
    func validatePrivateFallback(
        _ authorization: CmxIrohPrivateFallbackAuthorization
    ) async throws
}
