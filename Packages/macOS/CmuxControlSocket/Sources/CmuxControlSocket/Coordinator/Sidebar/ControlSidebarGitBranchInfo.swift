internal import Foundation

/// The reported git branch state for the `sidebar_state` listing.
public struct ControlSidebarGitBranchInfo: Sendable, Equatable {
    /// The branch name.
    public let branch: String
    /// Whether the working tree was reported dirty.
    public let isDirty: Bool

    /// Creates the info.
    ///
    /// - Parameters:
    ///   - branch: The branch name.
    ///   - isDirty: Whether the working tree was reported dirty.
    public init(branch: String, isDirty: Bool) {
        self.branch = branch
        self.isDirty = isDirty
    }
}
