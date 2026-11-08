/// Validation failures for a cmux Iroh stream header.
public enum CmxIrohStreamHeaderError: Error, Equatable, Sendable {
    /// The control stream did not supply an admission credential.
    case missingControlCredential

    /// A non-control stream attempted to carry a second credential.
    case credentialOnNonControlLane
}
