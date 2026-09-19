import Foundation

/// An authenticated, app-owned SOCKS5 endpoint. Its credential never enters a URL or log.
struct CloudBrowserProxyEndpoint: Sendable, Equatable, Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    let host: String
    let port: UInt16
    let username: String
    let password: String
    let websocketToken: String? = nil

    init(host: String, port: UInt16, username: String, password: String, websocketToken: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.websocketToken = websocketToken
    }

    var description: String { "CloudBrowserProxyEndpoint(\(host):\(port))" }
    var debugDescription: String { description }
}
