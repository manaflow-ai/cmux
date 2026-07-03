import Darwin
import Foundation

struct CmxManualHostParser {
    let rawHost: String
    let acceptsBareIPv6: Bool

    var normalizedHost: String? {
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
        if isBracketedHost || acceptsBareIPv6, isIPv6Literal(host) {
            return host
        }
        guard !isBracketedHost, isUnbracketedQRHost(host) else {
            return nil
        }
        return host
    }

    private func isUnbracketedQRHost(_ host: String) -> Bool {
        host.utf8.allSatisfy { byte in
            (48...57).contains(byte)        // 0-9
                || (65...90).contains(byte) // A-Z
                || (97...122).contains(byte) // a-z
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
        }
    }

    private func isIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
}
