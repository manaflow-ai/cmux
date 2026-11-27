public import Foundation

/// Why a batch workspace reorder request was rejected.
public enum WorkspaceBatchReorderError: Error, Equatable, Sendable {
    /// The request listed the workspace more than once.
    case duplicateWorkspace(UUID)
    /// The request named a workspace that is not in this window.
    case workspaceNotFound(UUID)
}
