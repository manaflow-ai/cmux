import Foundation

/// Identity for a browser access model. The loopback forward itself remains
/// keyed only by machine and port; scheme belongs to the browser route because
/// the raw relay supports HTTP but cannot carry HTTPS certificate identity.
public struct CloudPortAccessKey: Hashable, Sendable {
    public init(
        machineID: String,
        port: Int,
        scheme: String,
        route: CloudPortAccessRoute = .browserProxy
    ) {
        self.machineID = machineID
        self.port = port
        self.scheme = scheme
        self.route = route
    }

    public let machineID: String
    public let port: Int
    public let scheme: String
    /// The transport route is part of identity: a private-address proxy and a
    /// remote-loopback forward can serve the same port without sharing state.
    public let route: CloudPortAccessRoute
}
