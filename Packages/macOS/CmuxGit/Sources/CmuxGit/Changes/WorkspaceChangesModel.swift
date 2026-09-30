import Foundation

/// Aggregate workspace changes between the resolved base and working tree.
public struct WorkspaceChangesSummary: Sendable, Equatable {
    /// Whether the inspected directory belongs to a Git repository.
    public let isRepository: Bool
    /// The repository's absolute top-level path, or `nil` outside a repository.
    public let repoRoot: String?
    /// The checked-out branch name, or `nil` for a detached `HEAD`.
    public let branch: String?
    /// The default-branch reference used as the comparison base, or `nil` when comparing from `HEAD`.
    public let baseRef: String?
    /// The number of changed files in the full, uncapped result.
    public let filesChanged: Int
    /// The number of added lines in the full, uncapped result.
    public let additions: Int
    /// The number of deleted lines in the full, uncapped result.
    public let deletions: Int

    /// Creates an aggregate workspace-changes value.
    ///
    /// - Parameters:
    ///   - isRepository: Whether the inspected directory belongs to a repository.
    ///   - repoRoot: The repository's absolute top-level path.
    ///   - branch: The checked-out branch name.
    ///   - baseRef: The default-branch reference used as the comparison base.
    ///   - filesChanged: The number of changed files.
    ///   - additions: The number of added lines.
    ///   - deletions: The number of deleted lines.
    public init(
        isRepository: Bool,
        repoRoot: String?,
        branch: String?,
        baseRef: String?,
        filesChanged: Int,
        additions: Int,
        deletions: Int
    ) {
        self.isRepository = isRepository
        self.repoRoot = repoRoot
        self.branch = branch
        self.baseRef = baseRef
        self.filesChanged = filesChanged
        self.additions = additions
        self.deletions = deletions
    }

    /// The canonical result for a directory outside a Git repository.
    public static let notARepository = WorkspaceChangesSummary(
        isRepository: false,
        repoRoot: nil,
        branch: nil,
        baseRef: nil,
        filesChanged: 0,
        additions: 0,
        deletions: 0
    )
}

/// A wire-compatible category for one changed workspace path.
public enum WorkspaceChangeStatus: String, Sendable, Equatable {
    /// A tracked path was added.
    case added
    /// A tracked path was modified.
    case modified
    /// A tracked path was deleted.
    case deleted
    /// A tracked path was renamed.
    case renamed
    /// A path is not tracked by Git.
    case untracked
}

/// Per-file change metadata between the resolved base and working tree.
public struct WorkspaceChangedFile: Sendable, Equatable {
    /// The repository-relative current path.
    public let path: String
    /// The repository-relative previous path for a rename.
    public let oldPath: String?
    /// The file's change category.
    public let status: WorkspaceChangeStatus
    /// The number of added lines, or zero for binary content.
    public let additions: Int
    /// The number of deleted lines, or zero for binary content.
    public let deletions: Int
    /// Whether Git identified the file as binary.
    public let isBinary: Bool
    /// Whether a resource cap stopped line counting before end of file.
    public let isApproximate: Bool

    /// Creates per-file workspace-change metadata.
    ///
    /// - Parameters:
    ///   - path: The repository-relative current path.
    ///   - oldPath: The previous path for a rename.
    ///   - status: The file's change category.
    ///   - additions: The number of added lines.
    ///   - deletions: The number of deleted lines.
    ///   - isBinary: Whether Git identified the file as binary.
    ///   - isApproximate: Whether the additions count is partial.
    public init(
        path: String,
        oldPath: String?,
        status: WorkspaceChangeStatus,
        additions: Int,
        deletions: Int,
        isBinary: Bool,
        isApproximate: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isApproximate = isApproximate
    }
}

/// A changed-file listing and its uncapped aggregate totals.
public struct WorkspaceChangedFiles: Sendable, Equatable {
    /// Whether the inspected directory belongs to a Git repository.
    public let isRepository: Bool
    /// The repository's absolute top-level path, or `nil` outside a repository.
    public let repoRoot: String?
    /// The checked-out branch name, or `nil` for a detached `HEAD`.
    public let branch: String?
    /// The default-branch reference used as the comparison base, or `nil` when comparing from `HEAD`.
    public let baseRef: String?
    /// The path-sorted changed files, capped at 500 entries.
    public let files: [WorkspaceChangedFile]
    /// The number of changed files before the file-list cap.
    public let filesChanged: Int
    /// The number of added lines before the file-list cap.
    public let additions: Int
    /// The number of deleted lines before the file-list cap.
    public let deletions: Int
    /// Whether files or line counts were limited by a bounded snapshot operation.
    public let truncated: Bool

    /// Creates a changed-file listing.
    ///
    /// - Parameters:
    ///   - isRepository: Whether the inspected directory belongs to a repository.
    ///   - repoRoot: The repository's absolute top-level path.
    ///   - branch: The checked-out branch name.
    ///   - baseRef: The default-branch reference used as the comparison base.
    ///   - files: The capped, path-sorted changed files.
    ///   - filesChanged: The uncapped number of changed files.
    ///   - additions: The uncapped number of added lines.
    ///   - deletions: The uncapped number of deleted lines.
    ///   - truncated: Whether a list, command, or line-count cap limited the result.
    public init(
        isRepository: Bool,
        repoRoot: String?,
        branch: String?,
        baseRef: String?,
        files: [WorkspaceChangedFile],
        filesChanged: Int,
        additions: Int,
        deletions: Int,
        truncated: Bool
    ) {
        self.isRepository = isRepository
        self.repoRoot = repoRoot
        self.branch = branch
        self.baseRef = baseRef
        self.files = files
        self.filesChanged = filesChanged
        self.additions = additions
        self.deletions = deletions
        self.truncated = truncated
    }

    /// The canonical result for a directory outside a Git repository.
    public static let notARepository = WorkspaceChangedFiles(
        isRepository: false,
        repoRoot: nil,
        branch: nil,
        baseRef: nil,
        files: [],
        filesChanged: 0,
        additions: 0,
        deletions: 0,
        truncated: false
    )
}

/// A bounded unified diff for one changed workspace path.
public struct WorkspaceFileDiff: Sendable, Equatable {
    /// The repository-relative current path.
    public let path: String
    /// The repository-relative previous path for a rename.
    public let oldPath: String?
    /// The file's change category.
    public let status: WorkspaceChangeStatus
    /// Whether Git identified the file as binary.
    public let isBinary: Bool
    /// The number of added lines, or zero for binary content.
    public let additions: Int
    /// The number of deleted lines, or zero for binary content.
    public let deletions: Int
    /// Raw unified-diff output, empty for binary content.
    public let unifiedDiff: String
    /// Whether output was omitted at a hunk boundary by a size cap.
    public let truncated: Bool
    /// Number of lines in the full diff, or `nil` when bounded reading stopped early.
    public let totalLineCount: Int?
    /// Size, timestamps, device, and inode fingerprint for the current working file.
    public let contentFingerprint: String?

    /// Creates a bounded file-diff value.
    ///
    /// - Parameters:
    ///   - path: The repository-relative current path.
    ///   - oldPath: The previous path for a rename.
    ///   - status: The file's change category.
    ///   - isBinary: Whether Git identified the file as binary.
    ///   - additions: The number of added lines.
    ///   - deletions: The number of deleted lines.
    ///   - unifiedDiff: Raw, bounded unified-diff output.
    ///   - truncated: Whether a size cap omitted complete hunks.
    ///   - totalLineCount: Number of lines in the full diff, when known.
    ///   - contentFingerprint: Filesystem fingerprint for the current working file.
    public init(
        path: String,
        oldPath: String?,
        status: WorkspaceChangeStatus,
        isBinary: Bool,
        additions: Int,
        deletions: Int,
        unifiedDiff: String,
        truncated: Bool,
        totalLineCount: Int?,
        contentFingerprint: String?
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.isBinary = isBinary
        self.additions = additions
        self.deletions = deletions
        self.unifiedDiff = unifiedDiff
        self.truncated = truncated
        self.totalLineCount = totalLineCount
        self.contentFingerprint = contentFingerprint
    }
}

/// Failures specific to loading one workspace file diff.
public enum WorkspaceChangesServiceError: Error, Sendable, Equatable {
    /// The requested path was absolute or escaped the repository root.
    case invalidPath
    /// The directory is not inside a Git repository.
    case notARepository
    /// The requested path is not in the current changes snapshot.
    case fileNotChanged
    /// The path is not authorized for the requested changes revision.
    case forbidden
    /// The authorized file no longer exists at the requested revision.
    case fileNotFound
    /// Git failed while producing the requested diff.
    case gitFailure
}
