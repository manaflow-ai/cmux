import Foundation

/// A service inside the Cloud VM network: the machine's literal private address
/// and a TCP port.
struct CloudPortForwardTarget: Sendable, Hashable {
    let host: String
    let port: Int
}
