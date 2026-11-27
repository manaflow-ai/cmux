public import Foundation

/// Asks the system resolver whether a host name has an address. The seam
/// lets tests answer without DNS.
public nonisolated protocol HostLookup: Sendable {
    /// Whether `host` resolves (the system applies its DNS search domains to
    /// a single label, as Chrome does for `go` or `wiki`).
    func resolves(_ host: String) async -> Bool
}
