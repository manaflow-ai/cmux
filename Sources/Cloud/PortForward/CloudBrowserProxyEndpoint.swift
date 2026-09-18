import Foundation

/// An authenticated, app-owned CONNECT endpoint. Its credential never enters a URL or log.
struct CloudBrowserProxyEndpoint: Sendable, Equatable, Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    let host: String
    let port: UInt16
    let username: String
    let password: String

    var description: String { "CloudBrowserProxyEndpoint(\(host):\(port))" }
    var debugDescription: String { description }
}
