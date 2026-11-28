/// Validation failures for a persisted Iroh endpoint secret.
public enum CmxIrohSecretKeyError: Error, Equatable, Sendable {
    /// Iroh endpoint secrets are exactly 32 bytes.
    case invalidByteCount(Int)
}
