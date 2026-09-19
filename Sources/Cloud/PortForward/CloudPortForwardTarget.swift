import Foundation

/// A service inside the Cloud VM network: the machine's literal private address
/// and a TCP port.
struct CloudPortForwardTarget: Sendable, Hashable {
    let host: String
    let port: Int
    /// Other addresses advertised for this same machine. They are raced through
    /// the same hub; the private network remains the only route.
    var fallbackHosts: [String] = []

    var hosts: [String] {
        var seen = Set<String>()
        return ([host] + fallbackHosts).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
