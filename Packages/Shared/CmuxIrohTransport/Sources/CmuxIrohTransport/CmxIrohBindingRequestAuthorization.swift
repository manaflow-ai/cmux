public import CMUXMobileCore

/// Proof material that lets a fresh broker client act as one registered binding.
public struct CmxIrohBindingRequestAuthorization: Sendable {
    /// The exact broker binding whose endpoint key signs each request.
    public let bindingID: String

    let signer: CmxIrohRegistrationSigner

    /// Reconstructs request authorization from retained binding and identity state.
    ///
    /// - Parameters:
    ///   - bindingID: The exact registered broker binding identifier.
    ///   - identity: The endpoint identity material that owns the binding.
    ///   - endpointID: The endpoint identifier recorded on the binding.
    /// - Throws: ``CmxIrohRegistrationError/endpointIdentityMismatch`` when the
    ///   supplied identity does not derive the recorded endpoint.
    public init(
        bindingID: String,
        identity: CmxIrohIdentityMaterial,
        endpointID: CmxIrohPeerIdentity
    ) throws {
        self.bindingID = bindingID
        signer = try CmxIrohRegistrationSigner(
            identity: identity,
            endpointID: endpointID.endpointID
        )
    }

    init(bindingID: String, signer: CmxIrohRegistrationSigner) {
        self.bindingID = bindingID
        self.signer = signer
    }
}
