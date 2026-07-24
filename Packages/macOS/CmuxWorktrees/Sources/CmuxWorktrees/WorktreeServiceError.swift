import Foundation

/// A classified failure from ``WorktreeService``.
public enum WorktreeServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The requested host cannot currently execute commands.
    case hostUnavailable(WorktreeHostID)
    /// The identity belongs to a different execution host.
    case hostMismatch(expected: WorktreeHostID, actual: WorktreeHostID)
    /// A user-provided name sanitizes to an empty value.
    case invalidName(String)
    /// Git rejected the sanitized branch ref.
    case invalidBranch(String, reason: String)
    /// A path is empty, contains traversal, or cannot be resolved safely.
    case invalidPath(String)
    /// Git no longer reports the requested worktree.
    case worktreeNotFound(String)
    /// The main worktree cannot be removed.
    case mainWorktreeRemovalRefused(String)
    /// The worktree contains changes and force was not requested.
    case dirtyWorktree(path: String, fileCount: Int)
    /// The worktree is locked and must be explicitly unlocked first.
    case lockedWorktree(path: String, reason: String?)
    /// Git reports an orphaned gitdir rather than a removable working tree.
    case orphanedGitDirectory(path: String, message: String)
    /// A command exceeded its bounded deadline.
    case commandTimedOut(command: String, seconds: Double)
    /// A command could not launch or exited unsuccessfully.
    case commandFailed(command: String, exitStatus: Int32?, message: String)
    /// Submodule initialization failed after Git created the worktree.
    case submoduleInitializationFailed(path: String, message: String)

    /// A concise human-readable description of the classified failure.
    public var description: String {
        switch self {
        case let .hostUnavailable(host):
            return "Execution host '\(host.rawValue)' is unavailable."
        case let .hostMismatch(expected, actual):
            return "Worktree belongs to host '\(expected.rawValue)', not '\(actual.rawValue)'."
        case let .invalidName(name):
            return "Worktree name '\(name)' does not contain a Unicode letter or number."
        case let .invalidBranch(branch, reason):
            return "Invalid branch '\(branch)': \(reason)"
        case let .invalidPath(path):
            return "Invalid worktree path '\(path)'; path traversal is not allowed."
        case let .worktreeNotFound(path):
            return "Git does not report a worktree at '\(path)'."
        case let .mainWorktreeRemovalRefused(path):
            return "Refusing to remove the main worktree at '\(path)'."
        case let .dirtyWorktree(path, fileCount):
            return "Refusing to remove dirty worktree '\(path)' (\(fileCount) changed path(s)); pass force to discard them."
        case let .lockedWorktree(path, reason):
            let suffix = reason.map { ": \($0)" } ?? "."
            return "Refusing to remove locked worktree '\(path)'\(suffix)"
        case let .orphanedGitDirectory(path, message):
            return "Git reports '\(path)' is not a working tree; prune its orphaned administrative entry instead. \(message)"
        case let .commandTimedOut(command, seconds):
            return "Command timed out after \(Int(seconds))s: \(command)"
        case let .commandFailed(command, exitStatus, message):
            let status = exitStatus.map(String.init) ?? "unavailable"
            return "Command failed (status \(status)): \(command)\n\(message)"
        case let .submoduleInitializationFailed(path, message):
            return "Worktree was created at '\(path)', but submodule initialization failed: \(message)"
        }
    }
}
