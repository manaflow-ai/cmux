/// Trust-broker operations required by an iOS Iroh client runtime.
public protocol CmxIrohClientBrokerServing: CmxIrohRegistryServing,
    CmxIrohBindingRevoking
{
    /// Checks a caller-owned broker floor without performing network work.
    func preflight(operation: CmxIrohBrokerOperation) async throws

    /// Registers an endpoint using its challenge-bound identity proof.
    func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse

    /// Reports whether signed post-registration broker requests can be made.
    /// A rate-limited registration cannot establish this proof on a cold start.
    func hasBindingAuthorization() async -> Bool

    /// Returns the binding ID represented by the retained request proof.
    func bindingAuthorizationID() async -> String?

    /// Revokes one same-build Mac through the explicit account-management path.
    func forgetMac(bindingID: String) async throws
}

public extension CmxIrohClientBrokerServing {
    /// Accepts the operation when a conformer does not impose a local broker floor.
    func preflight(operation _: CmxIrohBrokerOperation) async throws {}

    /// Reports no retained request proof for conformers that do not persist one.
    func hasBindingAuthorization() async -> Bool { false }

    /// Reports no retained binding ID for conformers that do not persist proof.
    func bindingAuthorizationID() async -> String? { nil }
}

extension CmxIrohTrustBrokerClient: CmxIrohClientBrokerServing {}
