#if !canImport(IrohLib)
public import CMUXMobileCore

/// Where iroh-ffi does not exist (Linux, whose build has no Iroh
/// xcframework), no endpoint can bind: `bind` throws
/// ``CmxIrohEndpointUnavailableError``. Tests inject their own factory.
public struct CmxIrohLibEndpointFactory: CmxIrohEndpointFactory {
    /// Takes the IrohLib factory's parameter so callers compile unchanged.
    public init(
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic
    ) {}

    public func bind(
        configuration: CmxIrohEndpointConfiguration
    ) async throws -> any CmxIrohEndpoint {
        throw CmxIrohEndpointUnavailableError()
    }
}

/// The build has no Iroh endpoint implementation.
public struct CmxIrohEndpointUnavailableError: Error, Equatable, Sendable {
    public init() {}
}
#endif
