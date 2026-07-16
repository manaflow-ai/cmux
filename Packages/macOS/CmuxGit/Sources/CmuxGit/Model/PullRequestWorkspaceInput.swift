import Foundation

/// Identifies the workspace checkout whose current branch should be shown in the pull-request panel.
public struct PullRequestWorkspaceInput: Equatable, Hashable, Sendable {
    /// The workspace directory used to locate the enclosing git repository.
    public let directory: String

    /// The branch projected by the workspace git watcher, used to trigger refreshes when checkout changes.
    public let branchHint: String?

    /// Creates a workspace pull-request lookup input.
    /// - Parameters:
    ///   - directory: The workspace directory used to locate the enclosing repository.
    ///   - branchHint: The branch currently projected by the workspace git watcher.
    public init(directory: String, branchHint: String?) {
        self.directory = directory
        self.branchHint = branchHint
    }
}
