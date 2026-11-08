import Foundation

/// Target a workspace by durable key (preferred) or generation-scoped handle.
public enum WorkspaceRef: Sendable, Hashable {
    case key(WorkspaceKey)
    case handle(WorkspaceHandle)
}

struct WorkspaceRefFields: Encodable {
    var ref: WorkspaceRef
    enum CodingKeys: String, CodingKey { case key, workspace }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch ref {
        case .key(let key): try c.encode(key, forKey: .key)
        case .handle(let handle): try c.encode(handle, forKey: .workspace)
        }
    }
}

/// Result of create/rename/move/close-workspace.
public struct WorkspaceMutationResult: Decodable, Sendable, Equatable {
    public var workspace: WorkspaceHandle
    public var key: WorkspaceKey
    public var index: Int?
    public var workspaceRevision: UInt64
    public var changed: Bool?
    public var replayed: Bool
    public var registryID: String?
    public var generation: DaemonGeneration?

    /// The `mutation_id` of this new workspace's first chat tab (`agent.openSessionWorkspace`). Its key is the
    /// caller's, or derived from the run's idempotency key (`WorkspaceKey.generate()` in a ``DaemonCommandScope``),
    /// so an open repeated with the same key asks for the same tab and gets it back (`replayed`), never a second one;
    /// the handle gives a later workspace under the same key (the first one closed) its own tab.
    public var firstChatTabMutationID: String { "\(key.rawValue).\(workspace.rawValue).first-chat-tab" }

    enum CodingKeys: String, CodingKey {
        case workspace, key, index, changed, replayed, generation
        case workspaceRevision = "workspace_revision"
        case registryID = "registry_id"
    }
}
