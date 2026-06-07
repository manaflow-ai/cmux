import Foundation

/// A point-in-time read of a directory's git state, computed without spawning a
/// `git` process (the working tree, `HEAD`, and `index` are parsed directly).
///
/// Returned by ``GitMetadataService/workspaceMetadata(for:)``. The signature
/// fields let a caller cheaply detect "did anything change since last read"
/// without re-deriving the whole snapshot: re-read, compare signatures, and
/// only react when they differ.
public struct GitWorkspaceMetadata: Equatable, Sendable {
    /// Whether the directory resolved to a git repository at all. When `false`,
    /// every other field is its empty default.
    public let isRepository: Bool

    /// The current branch name (from `HEAD`), or `nil` for a detached HEAD or
    /// when `HEAD` is unreadable. The raw name as recorded in `HEAD`; callers
    /// that key state by branch should normalize (trim) it.
    public let branch: String?

    /// Whether the working tree has changes relative to the index (tracked-file
    /// modifications or a submodule pointer that no longer matches its checkout).
    public let isDirty: Bool

    /// A signature of the raw `index` file (its trailing checksum), or `nil`
    /// when the index is absent or too small. Changes whenever git rewrites the
    /// index, even if tracked content is unchanged.
    public let indexSignature: String?

    /// A signature derived only from tracked entry paths, modes, and object IDs
    /// (ignoring stat metadata), or `nil` when the index is unparseable. Stable
    /// across index rewrites that don't change tracked content, so it can
    /// rebaseline a clean working tree.
    public let indexContentSignature: String?

    /// A signature of `HEAD` plus the commit it points at (symbolic ref text and
    /// resolved value), or `nil` when `HEAD` is unreadable. Changes on checkout,
    /// commit, or reset.
    public let headSignature: String?

    /// Creates a workspace-metadata snapshot.
    public init(
        isRepository: Bool,
        branch: String?,
        isDirty: Bool,
        indexSignature: String?,
        indexContentSignature: String?,
        headSignature: String?
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.isDirty = isDirty
        self.indexSignature = indexSignature
        self.indexContentSignature = indexContentSignature
        self.headSignature = headSignature
    }

    /// The metadata for a directory that is not inside any git repository.
    public static let notARepository = GitWorkspaceMetadata(
        isRepository: false,
        branch: nil,
        isDirty: false,
        indexSignature: nil,
        indexContentSignature: nil,
        headSignature: nil
    )
}
