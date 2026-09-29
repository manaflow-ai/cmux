import Foundation

public struct CloseWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let command = "close-workspace"
    public var workspace: WorkspaceRef
    public var mutation: MutationIdentity?

    public init(workspace: WorkspaceRef, mutation: MutationIdentity?) {
        self.workspace = workspace
        self.mutation = mutation
    }

    public func encode(to encoder: any Encoder) throws {
        try WorkspaceRefFields(ref: workspace).encode(to: encoder)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
