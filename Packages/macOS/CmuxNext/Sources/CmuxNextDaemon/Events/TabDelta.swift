import Foundation

public struct TabDelta: Sendable, Hashable, Decodable {
    public var workspace: WorkspaceHandle
    public var screen: ScreenID
    public var pane: PaneID
    public var surface: SurfaceID
    public var index: Int?
    public var entity: TabSnapshot
    public var clientTransactionID: ClientTransactionID?

    public init(workspace: WorkspaceHandle, screen: ScreenID, pane: PaneID, surface: SurfaceID, index: Int?, entity: TabSnapshot,
                clientTransactionID: ClientTransactionID? = nil) {
        self.workspace = workspace
        self.screen = screen
        self.pane = pane
        self.surface = surface
        self.index = index
        self.entity = entity
        self.clientTransactionID = clientTransactionID
    }

    enum CodingKeys: String, CodingKey {
        case workspace, screen, pane, surface, index, entity
        case clientTransactionID = "transaction"
    }
}

public struct DaemonNotification: Sendable, Hashable, Decodable {
    public var notification: NotificationID
    public var title: String
    public var body: String
    public var level: NotificationLevel
    public var surface: SurfaceID?
    /// Not serialized on the `notification` event by current daemons; the
    /// `list-notifications` ledger carries `created_at_ms`.
    public var createdAtMs: UInt64?
    /// Who posted it (`notification-source-v1`: `cli`, `terminal` for OSC
    /// 9/777/99 the daemon parsed, `agent`, `daemon`); nil from older daemons.
    public var source: String?

    enum CodingKeys: String, CodingKey {
        case notification, title, body, level, surface, source
        case createdAtMs = "created_at_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notification = try c.decode(NotificationID.self, forKey: .notification)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        level = (try? c.decode(NotificationLevel.self, forKey: .level)) ?? .info
        surface = try c.decodeIfPresent(SurfaceID.self, forKey: .surface)
        createdAtMs = try c.decodeIfPresent(UInt64.self, forKey: .createdAtMs)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }
}

public struct ProjectionChange: Sendable, Hashable, Decodable {
    public var frontend: String
    public var scope: String
    public var subjectKey: String
    public var projectionRevision: UInt64
    public var origin: String?
    public var mutationID: String?

    enum CodingKeys: String, CodingKey {
        case frontend, scope, origin
        case subjectKey = "subject_key"
        case projectionRevision = "projection_revision"
        case mutationID = "mutation_id"
    }
}
