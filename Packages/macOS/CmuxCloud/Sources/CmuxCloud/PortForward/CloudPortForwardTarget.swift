import Foundation

/// A service inside the Cloud VM network: the machine's literal private address
/// and a TCP port.
public struct CloudPortForwardTarget: Sendable, Hashable {
    public init(
        host: String,
        port: Int,
        fallbackHosts: [String] = []
    ) {
        self.host = host
        self.port = port
        self.fallbackHosts = fallbackHosts
    }

    public let host: String
    public let port: Int
    /// Other addresses advertised for this same machine. They are raced through
    /// the same hub; the private network remains the only route.
    public var fallbackHosts: [String] = []

    public var hosts: [String] {
        var seen = Set<String>()
        return ([host] + fallbackHosts).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
