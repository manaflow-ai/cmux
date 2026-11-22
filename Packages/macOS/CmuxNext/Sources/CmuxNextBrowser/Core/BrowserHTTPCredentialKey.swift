import Foundation

/// Where a remembered HTTP sign-in applies: one browser profile, one server
/// (scheme, host, port), one realm and one method.
nonisolated struct BrowserHTTPCredentialKey: Hashable, Sendable {
    var profile: String
    var scheme: String
    var host: String
    var port: Int
    var realm: String
    var method: String

    init(profile: BrowserProfileID, space: URLProtectionSpace) {
        self.profile = profile.rawValue.uuidString
        // A proxy login never shares an item with a login of the same host.
        scheme = space.isProxy() ? "proxy-\(space.proxyType ?? "http")" : (space.protocol ?? "http")
        host = space.host
        port = space.port
        realm = space.realm ?? ""
        method = space.authenticationMethod
    }

    init(profile: String, scheme: String, host: String, port: Int, realm: String, method: String) {
        self.profile = profile
        self.scheme = scheme
        self.host = host
        self.port = port
        self.realm = realm
        self.method = method
    }

    /// The Keychain account: no secret, the server and realm only.
    var account: String { "\(profile)|\(scheme)://\(host):\(port)|\(method)|\(realm)" }
}

/// A user name and password the user chose to remember.
nonisolated struct BrowserHTTPRememberedLogin: Equatable, Sendable, Codable {
    var user: String
    var password: String
}

