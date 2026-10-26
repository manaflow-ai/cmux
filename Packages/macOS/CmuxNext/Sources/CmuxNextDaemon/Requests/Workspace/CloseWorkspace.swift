import Foundation

public struct CloseWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let commandName: DaemonCommandName = "close-workspace"
    public var workspace: WorkspaceRef
    /// Also end, in the same commit, each terminal whose tabs all close and
    /// that is not kept (`batch-close-v1`). Sent only when true.
    public var endTerminals: Bool
    /// Why it closes (`close-reason-v1`, with `endTerminals`); `.sessionEnd` keeps it out of
    /// closed history.
    public var reason: CloseReason?
    /// Close only when the workspace has no tab when the close commits
    /// (`close-workspace-if-empty-v1`); else the daemon refuses with
    /// `workspace_not_empty`. Sent only when true.
    public var ifEmpty: Bool
    public var mutation: MutationIdentity?

    public init(workspace: WorkspaceRef, endTerminals: Bool = false, reason: CloseReason? = nil,
                ifEmpty: Bool = false, mutation: MutationIdentity?) {
        self.workspace = workspace
        self.endTerminals = endTerminals
        self.reason = reason
        self.ifEmpty = ifEmpty
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case endTerminals = "end_terminals", reason, ifEmpty = "if_empty" }

    public func encode(to encoder: any Encoder) throws {
        try WorkspaceRefFields(ref: workspace).encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        if endTerminals {
            try c.encode(true, forKey: .endTerminals)
            try c.encodeIfPresent(reason?.rawValue, forKey: .reason)
        }
        if ifEmpty { try c.encode(true, forKey: .ifEmpty) }
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
