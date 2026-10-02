import Foundation

/// Identity for a browser access model. The loopback forward itself remains
/// keyed only by machine and port; scheme belongs to the browser route because
/// the raw relay supports HTTP but cannot carry HTTPS certificate identity.
public struct CloudPortAccessKey: Hashable, Sendable {
    public init(
        machineID: String,
        port: Int,
        scheme: String
    ) {
        self.machineID = machineID
        self.port = port
        self.scheme = scheme
    }

    public let machineID: String
    public let port: Int
    public let scheme: String
}
