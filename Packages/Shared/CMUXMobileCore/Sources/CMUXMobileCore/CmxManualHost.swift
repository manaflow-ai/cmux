import Darwin
import Foundation

/// A normalized host entered for an explicit mobile pairing attempt.
///
/// This value deliberately covers DNS names and IP literals in
/// addition to numeric Tailscale addresses. It is used only at an explicit
/// pairing boundary; automatic route discovery continues to use its own route
/// evidence and never treats this type as authorization.
public struct CmxManualHost: Equatable, Sendable {
    /// The normalized bare host, with IPv6 brackets and a DNS root dot removed.
    /// Scoped IPv6 literals retain their validated `%interface` zone suffix.
    public let rawValue: String

    /// Creates a normalized host from user input.
    /// - Parameter rawHost: A DNS name or IP literal. IPv6 input may be bracketed
    ///   and may carry a scoped-interface suffix such as `%en0`.
    public init?(_ rawHost: String) {
        guard let normalized = cmxManualHostNormalize(rawHost) else {
            return nil
        }
        rawValue = normalized
    }
}

private func cmxManualHostNormalize(_ rawHost: String) -> String? {
    let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let host: String
    let isBracketed = trimmed.hasPrefix("[") || trimmed.hasSuffix("]")
    if isBracketed {
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 else {
            return nil
        }
        host = String(trimmed.dropFirst().dropLast())
    } else {
        host = trimmed
    }

    guard !host.isEmpty,
          host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
          host.rangeOfCharacter(from: .controlCharacters) == nil,
          host.range(of: "://") == nil,
          host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@")) == nil else {
        return nil
    }

    if isBracketed && !host.contains(":") { return nil }
    if host.contains(":") {
        let components = host.split(separator: "%", omittingEmptySubsequences: false)
        guard components.count <= 2,
              !components.contains(where: { $0.isEmpty }) else {
            return nil
        }
        let literal = String(components[0])
        guard let canonicalIPv6 = cmxManualHostCanonicalIPv6(literal) else {
            return nil
        }
        if components.count == 2 {
            let zone = String(components[1])
            guard cmxManualHostValidIPv6Zone(zone) else { return nil }
            return "\(canonicalIPv6)%\(zone)"
        }
        return canonicalIPv6
    }

    // A dotted, all-numeric value is intended to be an IPv4 literal. Do
    // not let a malformed or ambiguous spelling become a DNS hostname.
    let numericHost = host.hasSuffix(".") ? String(host.dropLast()) : host
    if numericHost.contains("."), numericHost.utf8.allSatisfy({
        (48...57).contains($0) || $0 == UInt8(ascii: ".")
    }) {
        guard let canonicalIPv4 = cmxManualHostCanonicalIPv4(numericHost),
              canonicalIPv4 == numericHost else {
            return nil
        }
        return canonicalIPv4
    }

    guard host.utf8.allSatisfy({ byte in
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "_")
    }) else {
        return nil
    }

    let lowercased = host.lowercased()
    let canonical = lowercased.hasSuffix(".")
        ? String(lowercased.dropLast())
        : lowercased
    guard !canonical.isEmpty,
          canonical.utf8.count <= 253,
          !canonical.hasSuffix(".") else { return nil }
    let labels = canonical.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy({ label in
        !label.isEmpty
            && label.count <= 63
            && label.first != "-"
            && label.last != "-"
    }) else {
        return nil
    }
    return canonical
}

private func cmxManualHostCanonicalIPv4(_ host: String) -> String? {
    var address = in_addr()
    guard host.withCString({ inet_pton(AF_INET, $0, &address) == 1 }) else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
        return nil
    }
    return String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
    )
}

private func cmxManualHostCanonicalIPv6(_ host: String) -> String? {
    var address = in6_addr()
    guard host.withCString({ inet_pton(AF_INET6, $0, &address) == 1 }) else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
        return nil
    }
    return String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
    ).lowercased()
}

private func cmxManualHostValidIPv6Zone(_ zone: String) -> Bool {
    guard !zone.isEmpty, zone.utf8.count <= 63 else { return false }
    return zone.utf8.allSatisfy { byte in
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "_")
    }
}
