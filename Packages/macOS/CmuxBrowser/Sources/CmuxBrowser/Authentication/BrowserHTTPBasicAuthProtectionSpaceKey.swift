public import Foundation

public struct BrowserHTTPBasicAuthProtectionSpaceKey: Hashable {
    public let host: String
    public let port: Int
    public let protocolName: String?
    public let realm: String?
    public let authenticationMethod: String

    public init(_ protectionSpace: URLProtectionSpace) {
        host = protectionSpace.host
        port = protectionSpace.port
        protocolName = protectionSpace.`protocol`
        realm = protectionSpace.realm
        authenticationMethod = protectionSpace.authenticationMethod
    }
}
