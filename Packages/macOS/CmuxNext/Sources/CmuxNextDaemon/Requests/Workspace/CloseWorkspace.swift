import Foundation

public struct CloseWorkspaceRequest: DaemonRequest {
    public typealias Response = WorkspaceMutationResult
    public static let command = "close-workspace"
    public var workspace: WorkspaceRef
    /// Also end, in the same commit, each terminal whose tabs all close and
    /// that is not kept (`batch-close-v1`). Sent only when true.
    public var endTerminals: Bool
    /// Why it closes (`close-reason-v1`, with `endTerminals`); `.sessionEnd` keeps it out of
    /// closed history.
    public var reason: CloseReason?
    public var mutation: MutationIdentity?

    public init(workspace: WorkspaceRef, endTerminals: Bool = false, reason: CloseReason? = nil,
                mutation: MutationIdentity?) {
        self.workspace = workspace
        self.endTerminals = endTerminals
        self.reason = reason
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case endTerminals, reason }

    public func encode(to encoder: any Encoder) throws {
        try WorkspaceRefFields(ref: workspace).encode(to: encoder)
        if endTerminals {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(true, forKey: .endTerminals)
            try c.encodeIfPresent(reason?.rawValue, forKey: .reason)
        }
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
