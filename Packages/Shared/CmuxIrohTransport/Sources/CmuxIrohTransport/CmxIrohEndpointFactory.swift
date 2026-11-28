/// Binds concrete Iroh endpoint generations behind a testable seam.
public protocol CmxIrohEndpointFactory: Sendable {
    /// Binds one endpoint from a stable key and current relay credentials.
    ///
    /// - Parameter configuration: The complete immutable bind input.
    /// - Returns: A new active endpoint generation.
    /// - Throws: A transport or platform configuration error.
    func bind(
        configuration: CmxIrohEndpointConfiguration
    ) async throws -> any CmxIrohEndpoint
}
