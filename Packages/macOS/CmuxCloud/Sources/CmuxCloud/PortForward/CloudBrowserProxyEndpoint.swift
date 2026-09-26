import Foundation

/// An authenticated, app-owned browser proxy endpoint. Its credential never enters a URL or log.
public struct CloudBrowserProxyEndpoint: Sendable, Equatable, Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    public let host: String
    public let port: UInt16
    public let username: String
    public let password: String
    public var websocketToken: String?

    public init(host: String, port: UInt16, username: String, password: String, websocketToken: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.websocketToken = websocketToken
    }

    public var description: String { "CloudBrowserProxyEndpoint(\(host):\(port))" }
    public var debugDescription: String { description }
}
