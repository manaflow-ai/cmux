/// Validation failures for provider-qualified network profiles.
public enum CmxIrohNetworkProfileKeyError: Error, Equatable, Sendable {
    /// The provider-local identifier was empty, too long, or contained unsafe
    /// wire characters.
    case invalidProfileID
}
