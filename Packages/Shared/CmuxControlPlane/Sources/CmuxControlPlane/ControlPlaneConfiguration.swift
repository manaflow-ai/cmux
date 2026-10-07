public import CmuxMobileWire
public import Foundation

/// Where and how to connect: the owner's socket URL (`wss://…/v1/wire/host/<host>`),
/// what `hello` says, and the reconnect policy.
public struct ControlPlaneConfiguration: Sendable {
    public var url: URL
    public var client: HelloClient
    public var caps: [String]
    public var minVersion: Int
    public var maxVersion: Int
    public var reconnect: ReconnectPolicy
    /// Updates one subscriber may fall behind before the client drops its
    /// backlog and resyncs it from a fresh snapshot.
    public var streamBacklogLimit: Int
    /// Frames that may wait for the socket; past it sends fail with `.busy`.
    public var outboxLimit: Int

    public init(url: URL, client: HelloClient, caps: [String] = ["read", "signal", "presence", "resume"],
                minVersion: Int = 1, maxVersion: Int = 1, reconnect: ReconnectPolicy = ReconnectPolicy(),
                streamBacklogLimit: Int = 1024, outboxLimit: Int = 1024) {
        self.url = url
        self.client = client
        self.caps = caps
        self.minVersion = minVersion
        self.maxVersion = maxVersion
        self.reconnect = reconnect
        self.streamBacklogLimit = streamBacklogLimit
        self.outboxLimit = outboxLimit
    }

    /// Subprotocols of the upgrade: the wire name and the bearer (browsers cannot set headers;
    /// the token stays out of the URL and logs).
    public func protocols(token: String) -> [String] { ["cmux.wire.v1", "bearer.\(token)"] }
}
