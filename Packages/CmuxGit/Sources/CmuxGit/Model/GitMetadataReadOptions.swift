import Foundation

/// Controls how much repository metadata ``GitMetadataService`` reads.
///
/// The full mode preserves exact dirty/index behavior. The sidebar-large-repo
/// mode intentionally avoids worktree scans and index parsing so UI metadata
/// cannot compete with typing in very large repositories.
public struct GitMetadataReadOptions: Equatable, Sendable {
    public let checkWorkingTreeDirty: Bool
    public let includeIndexSignatures: Bool
    public let includeIndexContentSignature: Bool
    public let includeWorkTreeRootWatchPath: Bool
    public let includeIndexWatchPath: Bool
    public let includeGitlinkWatchPaths: Bool

    public init(
        checkWorkingTreeDirty: Bool,
        includeIndexSignatures: Bool,
        includeIndexContentSignature: Bool,
        includeWorkTreeRootWatchPath: Bool,
        includeIndexWatchPath: Bool,
        includeGitlinkWatchPaths: Bool
    ) {
        self.checkWorkingTreeDirty = checkWorkingTreeDirty
        self.includeIndexSignatures = includeIndexSignatures
        self.includeIndexContentSignature = includeIndexContentSignature
        self.includeWorkTreeRootWatchPath = includeWorkTreeRootWatchPath
        self.includeIndexWatchPath = includeIndexWatchPath
        self.includeGitlinkWatchPaths = includeGitlinkWatchPaths
    }

    /// Exact metadata: branch, dirty state, index signatures, and gitlink watch
    /// paths.
    public static let full = GitMetadataReadOptions(
        checkWorkingTreeDirty: true,
        includeIndexSignatures: true,
        includeIndexContentSignature: true,
        includeWorkTreeRootWatchPath: true,
        includeIndexWatchPath: true,
        includeGitlinkWatchPaths: true
    )

    /// Cheap sidebar metadata for large monorepos: branch/head/config/ref
    /// changes only. Dirty state, index signatures, worktree-wide watches, and
    /// recursive gitlink scans are intentionally disabled.
    public static let sidebarLargeRepository = GitMetadataReadOptions(
        checkWorkingTreeDirty: false,
        includeIndexSignatures: false,
        includeIndexContentSignature: false,
        includeWorkTreeRootWatchPath: false,
        includeIndexWatchPath: false,
        includeGitlinkWatchPaths: false
    )
}
