import Foundation

/// Errors returned when a capture, read, or catalog mutation is not safe.
public enum ArtifactStoreError: Error, Equatable, Sendable {
    /// The source is missing or is not a regular file/directory.
    case sourceUnavailable(String)
    /// The source is outside the explicit authorization roots.
    case unauthorizedPath(String)
    /// The source is a sensitive path that automatic capture must never read.
    case sensitivePath(String)
    /// A source exceeds the per-file or inline-content limit.
    case fileTooLarge(actual: Int64, limit: Int64)
    /// The catalog or payload directory is malformed or symlinked.
    case corruptCatalog(String)
    /// A requested record no longer exists.
    case recordNotFound(UUID)
    /// The requested artifact kind is not supported by this release.
    case unsupportedKind(String)
    /// The catalog exceeded a configured resource bound.
    case catalogLimitExceeded
}
