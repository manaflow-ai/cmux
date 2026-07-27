import Foundation

/// The on-disk locations that define a single resolved git repository.
///
/// Produced by ``GitMetadataService`` when it walks upward from a directory to
/// the nearest `.git`. The three paths are kept distinct because worktrees and
/// submodules split the git directory from the shared common directory:
///
/// - For a normal clone, all three describe the same checkout: ``workTreeRoot``
///   is the checkout root, ``gitDirectory`` is its `.git`, and
///   ``commonDirectory`` equals ``gitDirectory``.
/// - For a linked worktree (`git worktree add`) or a submodule, the `.git`
///   entry is a file pointing elsewhere, so ``gitDirectory`` is the per-worktree
///   git dir while ``commonDirectory`` (read from `commondir`) is the shared
///   object/ref store. Refs and config may live under either.
public struct ResolvedGitRepository: Equatable, Sendable {
    /// Absolute path to the working-tree root (the directory containing `.git`).
    public let workTreeRoot: String

    /// Absolute path to this checkout's git directory (the `.git` directory, or
    /// the directory a `.git` *file* points at for worktrees/submodules).
    public let gitDirectory: String

    /// Absolute path to the shared common directory (``gitDirectory`` for a
    /// normal clone; the `commondir` target for a linked worktree). Holds the
    /// shared `refs`, `packed-refs`, and `config`.
    public let commonDirectory: String

    /// Creates a resolved repository from its three on-disk locations.
    public init(workTreeRoot: String, gitDirectory: String, commonDirectory: String) {
        self.workTreeRoot = workTreeRoot
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
    }
}
