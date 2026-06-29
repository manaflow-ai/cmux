import Foundation

struct BrowserClientCertificateProtectionSpaceKey: Hashable {
    let host: String
    let port: Int
    let protocolName: String?
    let distinguishedNames: [Data]?
    let authenticationMethod: String

    init(_ protectionSpace: URLProtectionSpace) {
        host = protectionSpace.host
        port = protectionSpace.port
        protocolName = protectionSpace.`protocol`
        distinguishedNames = protectionSpace.distinguishedNames
        authenticationMethod = protectionSpace.authenticationMethod
    }
}
