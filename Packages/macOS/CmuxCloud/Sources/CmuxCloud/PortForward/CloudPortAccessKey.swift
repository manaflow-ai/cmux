import Foundation

/// Identity for a browser access model. The target host is part of the key
/// because an authenticated proxy can carry several origins on one machine and
/// port (for example a private address and `localhost`) without sharing their
/// TLS or WebKit navigation state.
public struct CloudPortAccessKey: Hashable, Sendable {
    public init(
        machineID: String,
        port: Int,
        scheme: String,
        targetHost: String = "",
        route: CloudPortAccessRoute = .browserProxy
    ) {
        self.machineID = machineID
        self.port = port
        self.scheme = scheme
        self.targetHost = targetHost
        self.route = route
    }

    public let machineID: String
    public let port: Int
    public let scheme: String
    public let targetHost: String
    /// The transport route is part of identity: a private-address proxy and a
    /// remote-loopback forward can serve the same port without sharing state.
    public let route: CloudPortAccessRoute
}
