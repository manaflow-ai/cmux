public import Foundation

/// A phone connection that can be used: it listed a non-empty workspace set
/// and subscribed to workspace state and terminal output with its client id.
/// The App publishes it as the `mobile.rpc.ready` event the iOS dogfood
/// launcher waits for (payload keys match the old app's event).
public struct MobileUsableSession: Sendable, Equatable {
    public var connectionID: String
    public var clientID: String
    public var streamID: String
    public var transport: String
    public var workspaceCount: Int

    public init(connectionID: String, clientID: String, streamID: String, transport: String, workspaceCount: Int) {
        self.connectionID = connectionID
        self.clientID = clientID
        self.streamID = streamID
        self.transport = transport
        self.workspaceCount = workspaceCount
    }
}

/// Per-connection readiness: both halves, published once.
struct MobileReadiness: Sendable {
    let connectionID = UUID().uuidString
    var workspaceCount: Int?
    var subscription: (clientID: String, streamID: String, transport: String)?
    var published = false

    /// `mobile.events.subscribe` params that make a session usable.
    static func subscription(topics: [String], clientID: String?, streamID: String, transport: String)
        -> (clientID: String, streamID: String, transport: String)? {
        let set = Set(topics)
        guard set.contains("workspace.updated"), set.contains("mobile.sync.delta"),
              set.contains("terminal.bytes") || set.contains("terminal.render_grid"),
              let clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else { return nil }
        return (clientID, streamID, transport)
    }

    /// The session to publish now, if it just became usable.
    mutating func ready() -> MobileUsableSession? {
        guard !published, let workspaceCount, workspaceCount > 0, let subscription else { return nil }
        published = true
        return MobileUsableSession(connectionID: connectionID, clientID: subscription.clientID, streamID: subscription.streamID,
                                   transport: subscription.transport, workspaceCount: workspaceCount)
    }
}
