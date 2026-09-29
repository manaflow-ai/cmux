import Foundation

// Subscribe-stream events (cmux-tui/spec/events.md). Unknown events decode
// to `.unknown` with the raw payload so a newer daemon never breaks the app.

/// Ordered workspace delta (`workspace-added/closed/renamed/moved/changed`).
public struct WorkspaceDelta: Sendable, Hashable, Decodable {
    public var workspace: WorkspaceHandle
    /// Insertion index (added), former index (closed), new index (moved); nil for renamed.
    public var index: Int?
    public var entity: WorkspaceSnapshot
    public var workspaceRevision: UInt64
    public var registryID: String?
    public var generation: DaemonGeneration?
    public var origin: String?
    public var mutationID: String?
    /// TODO(feat-cmux-next-daemon): echo of the command's client transaction id.
    public var clientTransactionID: ClientTransactionID?

    public init(workspace: WorkspaceHandle, index: Int?, entity: WorkspaceSnapshot, workspaceRevision: UInt64,
                registryID: String? = nil, generation: DaemonGeneration? = nil, origin: String? = nil, mutationID: String? = nil,
                clientTransactionID: ClientTransactionID? = nil) {
        self.workspace = workspace
        self.index = index
        self.entity = entity
        self.workspaceRevision = workspaceRevision
        self.registryID = registryID
        self.generation = generation
        self.origin = origin
        self.mutationID = mutationID
        self.clientTransactionID = clientTransactionID
    }

    enum CodingKeys: String, CodingKey {
        case workspace, index, entity, generation, origin
        case workspaceRevision = "workspace_revision"
        case registryID = "registry_id"
        case mutationID = "mutation_id"
        case clientTransactionID = "client_transaction_id"
    }
}

public struct ScreenDelta: Sendable, Hashable, Decodable {
    public var workspace: WorkspaceHandle
    public var screen: ScreenID
    public var index: Int?
    public var entity: ScreenSnapshot
    public var clientTransactionID: ClientTransactionID?

    enum CodingKeys: String, CodingKey {
        case workspace, screen, index, entity
        case clientTransactionID = "client_transaction_id"
    }
}

public struct PaneDelta: Sendable, Hashable, Decodable {
    public var workspace: WorkspaceHandle
    public var screen: ScreenID
    public var pane: PaneID
    public var index: Int?
    public var entity: PaneSnapshot
    public var clientTransactionID: ClientTransactionID?

    enum CodingKeys: String, CodingKey {
        case workspace, screen, pane, index, entity
        case clientTransactionID = "client_transaction_id"
    }
}
