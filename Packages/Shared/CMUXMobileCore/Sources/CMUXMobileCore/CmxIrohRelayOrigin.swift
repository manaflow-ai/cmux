import Foundation

/// Produces credential-free HTTPS origins suitable for an IT allowlist.
public enum CmxIrohRelayOrigin {
    /// Drops unsafe relay URL components and returns unique, sorted origins.
    public static func canonicalOrigins(from relayURLs: [String]) -> [String] {
        Array(Set(relayURLs.compactMap(canonicalOrigin))).sorted()
    }

    private static func canonicalOrigin(_ rawValue: String) -> String? {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }

        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = components.port
        return origin.string
    }
}
