public import CmuxMobileShellModel
public import Foundation

/// Optional parameters for a mobile `workspace.create` request.
public struct MobileWorkspaceCreateSpec: Equatable, Sendable {
    /// Workspace title.
    public var title: String?
    /// Initial working directory.
    public var workingDirectory: String?
    /// Initial terminal command.
    public var initialCommand: String?
    /// Initial terminal environment.
    public var initialEnv: [String: String]?
    /// Phone-side identifier of the workspace group that should contain the
    /// new workspace, or `nil` to create it ungrouped.
    ///
    /// Aggregate identifiers are resolved to the owning Mac's RPC identifier
    /// by the shell before the request is sent.
    public var workspaceGroupID: MobileWorkspaceGroupPreview.ID?
    /// Stable identity for idempotent retry of one logical create operation.
    public var operationID: UUID?

    /// Creates optional workspace-create parameters.
    /// - Parameters:
    ///   - title: Workspace title.
    ///   - workingDirectory: Initial working directory.
    ///   - initialCommand: Initial terminal command.
    ///   - initialEnv: Initial terminal environment.
    ///   - workspaceGroupID: Optional destination workspace group.
    public init(
        title: String? = nil,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        initialEnv: [String: String]? = nil,
        workspaceGroupID: MobileWorkspaceGroupPreview.ID? = nil,
        operationID: UUID? = nil
    ) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.initialCommand = initialCommand
        self.initialEnv = initialEnv
        self.workspaceGroupID = workspaceGroupID
        self.operationID = operationID
    }
}
