import Foundation

/// The callback that ends a sign-in session: a custom scheme, or an https
/// host and path. The same rule as the system's matcher: scheme and host
/// compare without case, the path ignores one trailing slash, query and
/// fragment do not count (the shim's `auth_callback_policy.h` is the C++ copy).
nonisolated enum WebAuthCallback: Equatable, Sendable {
    case customScheme(String)
    case https(host: String, path: String)
    /// Unknown: nothing matches by this rule (the request's own matcher may).
    case none

    func matches(_ url: URL) -> Bool {
        switch self {
        case .customScheme(let scheme):
            return url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
        case .https(let host, let path):
            guard url.scheme?.lowercased() == "https", let urlHost = url.host(percentEncoded: false) else { return false }
            if let port = url.port, port != 443 { return false }
            guard Self.trimmedHost(urlHost) == Self.trimmedHost(host) else { return false }
            return Self.trimmedPath(url.path(percentEncoded: true)) == Self.trimmedPath(path)
        case .none:
            return false
        }
    }

    private static func trimmedHost(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func trimmedPath(_ path: String) -> String {
        var path = path.isEmpty ? "/" : path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
