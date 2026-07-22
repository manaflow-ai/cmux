/// The proof used to admit an Iroh control stream.
public enum CmxIrohAdmissionCredentialKind: Equatable, Sendable {
    /// A backend-signed grant binding the two exact EndpointIDs.
    case pairGrant

    /// Cached same-account endpoint attestation plus a one-use local invitation.
    case offlinePairing
}
