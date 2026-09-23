public import Foundation

/// Reads the committed state that an editor compares its buffer against, and
/// reports which repository paths move it.
///
/// ``SystemGitHeadContentReader`` is the production conformance. Consumers
/// depend on this protocol so tests can supply fixed content without a
/// repository.
public protocol GitHeadContentReading: Sendable {
    /// Returns the bytes of a file as committed at HEAD.
    ///
    /// Bytes rather than text let the caller decode with the same encoding it
    /// used for the working copy, so a Latin-1 or UTF-16 file compares cleanly.
    ///
    /// - Parameter absolutePath: The file's absolute path.
    /// - Returns: The committed bytes, or `nil` when the file is untracked,
    ///   outside a repository, too large, or git fails.
    func headContent(forFile absolutePath: String) async -> Data?

    /// Returns the repository paths whose changes can move HEAD content.
    ///
    /// The list covers `HEAD`, `index`, the checked-out branch's loose ref,
    /// `packed-refs`, and `reftable` when present. `HEAD` and the ref catch
    /// commits and resets that leave the index alone, such as
    /// `git reset --soft`. The branch ref changes on checkout, so callers
    /// resolve the list again after any of these paths change.
    ///
    /// - Parameter absolutePath: The file's absolute path.
    /// - Returns: Existing absolute paths, sorted, or `nil` outside a
    ///   repository.
    func watchedPaths(forFile absolutePath: String) async -> [String]?
}
