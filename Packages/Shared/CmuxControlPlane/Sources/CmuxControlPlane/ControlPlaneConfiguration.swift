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

    public init(url: URL, client: HelloClient, caps: [String] = ["read", "signal", "presence", "resume"],
                minVersion: Int = 1, maxVersion: Int = 1, reconnect: ReconnectPolicy = ReconnectPolicy()) {
        self.url = url
        self.client = client
        self.caps = caps
        self.minVersion = minVersion
        self.maxVersion = maxVersion
        self.reconnect = reconnect
    }

    /// Subprotocols of the upgrade: the wire name and the bearer (browsers cannot set headers;
    /// the token stays out of the URL and logs).
    public func protocols(token: String) -> [String] { ["cmux.wire.v1", "bearer.\(token)"] }
}
