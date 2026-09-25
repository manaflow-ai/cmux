import Foundation

/// Caches tokened preview URLs for one cloud-machine surface provider.
/// Endpoints are scoped by port and replaced atomically when a newer lease is minted.
struct SurfacePortEndpointCache {
    private var values: [Int: String] = [:]

    public func openURL(port: Int) -> String? {
        values[port]
    }

    public mutating func store(openURL: String, port: Int) {
        values[port] = openURL
    }
}
