import Darwin
import Foundation

/// A normalized user-entered host for explicit manual mobile pairing routes.
///
/// Manual hosts are DNS names or IP literals that a user deliberately chooses
/// outside automatic Tailscale discovery. The value is only a host, never a URL:
/// schemes, paths, query/fragment markers, user-info markers, bare colon host
/// text, non-QR-safe characters, whitespace, and control characters are rejected
/// before the host is advertised or dialed.
public struct CmxManualHost: Equatable, Sendable {
    /// The normalized bare host, with IPv6 brackets removed when present.
    public let rawValue: String

    /// Creates a normalized manual host.
    ///
    /// - Parameter rawHost: A DNS name or IP literal. IPv6 literals must be
    ///   bracketed (`[fd00::1]`) so ordinary hostnames cannot hide colons.
    public init?(_ rawHost: String) {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let host: String
        let isBracketedHost: Bool
        if trimmed.hasPrefix("[") || trimmed.hasSuffix("]") {
            guard trimmed.hasPrefix("["),
                  trimmed.hasSuffix("]"),
                  trimmed.count > 2 else {
                return nil
            }
            host = String(trimmed.dropFirst().dropLast())
            isBracketedHost = true
        } else {
            host = trimmed
            isBracketedHost = false
        }
        guard !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil,
              host.range(of: "://") == nil else {
            return nil
        }
        if isBracketedHost {
            guard Self.isIPv6Literal(host) else {
                return nil
            }
        } else {
            guard Self.isUnbracketedQRHost(host) else {
                return nil
            }
        }
        self.rawValue = host
    }

    /// Normalizes a host that may already be in attach-route endpoint form.
    ///
    /// User-entered IPv6 must be bracketed so a typo like `my:host` is rejected
    /// up front. Attach routes store IPv6 without brackets, so route/reconnect
    /// paths use this helper when they are validating an already-normalized
    /// endpoint host.
    public static func normalizedRouteHost(_ rawHost: String) -> String? {
        if let manualHost = CmxManualHost(rawHost) {
            return manualHost.rawValue
        }
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("["),
              !trimmed.hasSuffix("]"),
              Self.isIPv6Literal(trimmed) else {
            return nil
        }
        return trimmed
    }

    private static func isUnbracketedQRHost(_ host: String) -> Bool {
        host.utf8.allSatisfy { byte in
            (48...57).contains(byte)        // 0-9
                || (65...90).contains(byte) // A-Z
                || (97...122).contains(byte) // a-z
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
        }
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
}
