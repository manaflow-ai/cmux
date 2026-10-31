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
    /// `notify --subtitle`; nil from older daemons.
    public var subtitle: String?
    public var body: String
    /// An agent's last message for its turn's banner, memory only on the daemon; nil from
    /// older daemons and for every other notification.
    public var preview: String?
    public var level: NotificationLevel
    public var surface: SurfaceID?
    /// The workspace of a notification with no terminal (`cmux notify --workspace ws_…`,
    /// its public id); nil for a terminal's notification and from older daemons.
    public var workspaceID: ResourceID?
    /// Not serialized on the `notification` event by current daemons; the
    /// `list-notifications` ledger carries `created_at_ms`.
    public var createdAtMs: UInt64?
    /// Who posted it (`notification-source-v1`: `cli`, `terminal` for OSC
    /// 9/777/99 the daemon parsed, `agent`, `daemon`); nil from older daemons.
    public var source: String?
    /// false: the poster asked for no desktop banner (`notify --desktop false`,
    /// `notification-desktop-v1`); true from older daemons.
    public var desktop: Bool
    /// true: the banner takes a typed reply for the notifying terminal
    /// (`notify --reply`, `notification-reply-v1`); false from older daemons.
    public var reply: Bool

    enum CodingKeys: String, CodingKey {
        case notification, title, subtitle, body, preview, level, surface, source, desktop, reply
        case createdAtMs = "created_at_ms"
        case workspaceID = "workspace_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notification = try c.decode(NotificationID.self, forKey: .notification)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        level = (try? c.decode(NotificationLevel.self, forKey: .level)) ?? .info
        surface = try c.decodeIfPresent(SurfaceID.self, forKey: .surface)
        workspaceID = try? c.decodeIfPresent(ResourceID.self, forKey: .workspaceID)
        createdAtMs = try c.decodeIfPresent(UInt64.self, forKey: .createdAtMs)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        desktop = (try? c.decodeIfPresent(Bool.self, forKey: .desktop)) ?? true
        reply = (try? c.decodeIfPresent(Bool.self, forKey: .reply)) ?? false
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
