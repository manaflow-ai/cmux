import Foundation

struct BrowserClientCertificateProtectionSpaceKey: Hashable {
    let host: String
    let port: Int
    let protocolName: String?
    let distinguishedNames: [Data]?
    let authenticationMethod: String

    init(_ protectionSpace: URLProtectionSpace) {
        self.init(
            host: protectionSpace.host,
            port: protectionSpace.port,
            protocolName: protectionSpace.`protocol`,
            distinguishedNames: protectionSpace.distinguishedNames,
            authenticationMethod: protectionSpace.authenticationMethod
        )
    }

    init(
        host: String,
        port: Int,
        protocolName: String?,
        distinguishedNames: [Data]?,
        authenticationMethod: String
    ) {
        self.host = host
        self.port = port
        self.protocolName = protocolName
        self.distinguishedNames = (distinguishedNames?.isEmpty == false) ? distinguishedNames : nil
        self.authenticationMethod = authenticationMethod
    }
}
