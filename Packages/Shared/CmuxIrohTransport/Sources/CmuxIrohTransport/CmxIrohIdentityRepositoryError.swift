/// Failures while reconciling device-local Iroh identity state.
public enum CmxIrohIdentityRepositoryError: Error, Equatable, Sendable {
    /// The account or app-instance identifier is empty or too large.
    case invalidScope

    /// Stored identity bytes do not match the versioned record contract.
    case corruptRecord

    /// The identity generation is zero, exhausted, or database-incompatible.
    case invalidGeneration

    /// Secure random generation failed with the platform status code.
    case randomGenerationFailed(Int32)
}
