/// Validation failures for provider-qualified network profiles.
public enum CmxIrohNetworkProfileKeyError: Error, Equatable, Sendable {
    /// The identifier was not a canonical lowercase-hex 32-byte digest.
    case invalidProfileID
}
