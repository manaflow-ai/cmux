package import Foundation

/// Where a remembered HTTP sign-in applies: one browser profile, one server
/// (scheme, host, port), one realm and one method.
package nonisolated struct BrowserHTTPCredentialKey: Hashable, Sendable {
    package var profile: String
    package var scheme: String
    package var host: String
    package var port: Int
    package var realm: String
    package var method: String

    package init(profile: BrowserProfileID, space: URLProtectionSpace) {
        self.profile = profile.rawValue.uuidString
        // A proxy login never shares an item with a login of the same host.
        scheme = space.isProxy() ? "proxy-\(space.proxyType ?? "http")" : (space.protocol ?? "http")
        host = space.host
        port = space.port
        realm = space.realm ?? ""
        method = space.authenticationMethod
    }

    package init(profile: String, scheme: String, host: String, port: Int, realm: String, method: String) {
        self.profile = profile
        self.scheme = scheme
        self.host = host
        self.port = port
        self.realm = realm
        self.method = method
    }

    /// The Keychain account: no secret, the server and realm only.
    package var account: String { "\(profile)|\(scheme)://\(host):\(port)|\(method)|\(realm)" }
}

/// A user name and password the user chose to remember.
package nonisolated struct BrowserHTTPRememberedLogin: Equatable, Sendable, Codable {
    package var user: String
    package var password: String

    package init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

