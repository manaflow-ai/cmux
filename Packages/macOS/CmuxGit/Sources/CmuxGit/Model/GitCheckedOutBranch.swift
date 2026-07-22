import Foundation

/// The result of reading a directory's checked-out branch from its
/// repository's `HEAD`.
///
/// Distinguishes a legitimate non-branch checkout (``detached``) from a
/// repository whose `HEAD` could not be read or parsed (``unreadable``), so
/// callers can treat the latter as an unverified state instead of trusting a
/// possibly stale projection.
public enum GitCheckedOutBranch: Equatable, Sendable {
    /// The repository is checked out on the associated (normalized) branch.
    case branch(String)
    /// `HEAD` is readable but does not name a branch: a detached commit or a
    /// non-branch symbolic ref.
    case detached
    /// The directory is not inside a git repository.
    case notARepository
    /// The repository exists but `HEAD` is missing, unreadable, or malformed.
    case unreadable
}
