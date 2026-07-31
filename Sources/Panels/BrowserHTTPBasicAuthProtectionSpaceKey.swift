import Foundation

struct BrowserHTTPBasicAuthProtectionSpaceKey: Hashable {
    let host: String
    let port: Int
    let protocolName: String?
    let realm: String?
    let authenticationMethod: String

    init(_ protectionSpace: URLProtectionSpace) {
        host = protectionSpace.host
        port = protectionSpace.port
        protocolName = protectionSpace.`protocol`
        realm = protectionSpace.realm
        authenticationMethod = protectionSpace.authenticationMethod
    }
}
