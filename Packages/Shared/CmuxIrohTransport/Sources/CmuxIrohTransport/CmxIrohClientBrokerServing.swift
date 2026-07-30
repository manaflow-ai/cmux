/// Trust-broker operations required by an iOS Iroh client runtime.
public protocol CmxIrohClientBrokerServing: CmxIrohRegistryServing,
    CmxIrohRelayTokenServing, CmxIrohBindingRevoking
{
    /// Checks a caller-owned broker floor without performing network work.
    func preflight(operation: CmxIrohBrokerOperation) async throws

    /// Registers an endpoint using its challenge-bound identity proof.
    func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse

    /// Revokes one same-build Mac through the explicit account-management path.
    func forgetMac(bindingID: String) async throws
}

public extension CmxIrohClientBrokerServing {
    /// Accepts the operation when a conformer does not impose a local broker floor.
    func preflight(operation _: CmxIrohBrokerOperation) async throws {}

    /// Falls back to ordinary revocation for conformers without a management route.
    func forgetMac(bindingID: String) async throws {
        try await revoke(bindingID: bindingID)
    }
}

extension CmxIrohTrustBrokerClient: CmxIrohClientBrokerServing {}
