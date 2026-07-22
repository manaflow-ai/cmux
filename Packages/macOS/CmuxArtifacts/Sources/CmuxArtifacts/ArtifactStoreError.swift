import Foundation

/// Errors surfaced by artifact persistence and CLI operations.
public enum ArtifactStoreError: Error, Equatable, Sendable {
    /// The source path does not exist or is not a regular file.
    case sourceNotRegularFile(String)
    /// The filename extension is not permitted by project policy.
    case unsupportedExtension(String)
    /// The source exceeds the configured byte limit.
    case fileTooLarge(actual: Int64, limit: Int64)
    /// A requested artifact name was missing.
    case artifactNotFound(String)
    /// A name matched more than one artifact and requires a more specific path.
    case ambiguousArtifactName(String, matches: [String])
    /// The resolved path escaped the artifact store boundary.
    case pathOutsideStore(String)
    /// Existing content-addressed provenance could not be decoded safely.
    case corruptProvenance(String)
}
