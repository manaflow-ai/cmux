import Foundation

/// The cmuxd proxy endpoint a remote workspace's browser traffic routes
/// through.
struct BrowserProxyEndpoint: Equatable {
    let host: String
    let port: Int
}
