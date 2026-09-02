import Foundation

/// The only bind-address classes accepted by ``WebClientBridgeService``.
///
/// Browser access is intentionally explicit: loopback is local-only, while a
/// user may name one Tailscale CGNAT address in `100.64.0.0/10`. Hostnames,
/// wildcard addresses, and every other interface are rejected before a socket
/// is created.
nonisolated struct WebClientBridgeBindAddress: Equatable, Sendable {
    enum Kind: String, Sendable {
        case loopback
        case tailscale
    }

    let host: String
    let kind: Kind

    var urlHost: String {
        host.contains(":") ? "[\(host)]" : host
    }

    enum ValidationError: Error, Equatable, Sendable {
        case empty
        case wildcard
        case unsupported
    }

    init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ValidationError.empty }
        guard value != "0.0.0.0", value != "::", value != "*" else {
            throw ValidationError.wildcard
        }

        if value == "localhost" || value == "127.0.0.1" || value == "::1" {
            host = value == "localhost" ? "127.0.0.1" : value
            kind = .loopback
            return
        }

        guard let ipv4 = Self.parseIPv4(value) else {
            throw ValidationError.unsupported
        }
        if ipv4[0] == 127 {
            host = value
            kind = .loopback
            return
        }
        // Tailscale's IPv4 CGNAT range is 100.64.0.0/10.
        let isTailscale = ipv4[0] == 100 && (64 ... 127).contains(ipv4[1])
        guard isTailscale else { throw ValidationError.unsupported }
        host = value
        kind = .tailscale
    }

    /// A pure validation helper used by tests and CLI argument parsing.
    static func validate(_ rawValue: String) -> Result<Self, ValidationError> {
        do { return .success(try Self(rawValue)) }
        catch let error as ValidationError { return .failure(error) }
        catch { return .failure(.unsupported) }
    }

    private static func parseIPv4(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else {
            return nil
        }
        return octets
    }
}
