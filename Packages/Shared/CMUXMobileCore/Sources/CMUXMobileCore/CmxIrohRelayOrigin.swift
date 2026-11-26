import Foundation

public extension Sequence where Element == String {
    /// Returns unique, sorted, credential-free HTTPS origins suitable for an IT allowlist.
    func cmxIrohCanonicalRelayOrigins() -> [String] {
        Array(Set(compactMap { rawValue in
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
        })).sorted()
    }
}
