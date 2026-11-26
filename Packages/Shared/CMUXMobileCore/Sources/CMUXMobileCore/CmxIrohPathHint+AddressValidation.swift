import Darwin
import Foundation

private struct CmxIrohPathHintValidator {
  let hint: CmxIrohPathHint

  /// Returns `nil` for malformed socket syntax, otherwise whether the IP is
  /// allowed as a remote Iroh peer address.
  private func directSocketAddressIsAllowed(_ value: String) -> Bool? {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.count <= 80,
      !value.contains("/"),
      !value.contains("@"),
      !value.contains("?") && !value.contains("#")
    else {
      return nil
    }
    if value.hasPrefix("[") {
      guard let closingBracket = value.firstIndex(of: "]"),
        value.index(after: closingBracket) < value.endIndex,
        value[value.index(after: closingBracket)] == ":"
      else {
        return nil
      }
      let host = String(value[value.index(after: value.startIndex)..<closingBracket])
      let portStart = value.index(closingBracket, offsetBy: 2)
      let port = String(value[portStart...])
      guard !host.contains("%"),
        let addressIsAllowed = ipv6LiteralIsAllowed(host),
        isCanonicalPort(port)
      else {
        return nil
      }
      return addressIsAllowed
    }
    guard let separator = value.lastIndex(of: ":"),
      value[..<separator].contains(":") == false
    else {
      return nil
    }
    let host = String(value[..<separator])
    let port = String(value[value.index(after: separator)...])
    guard let octets = canonicalIPv4Octets(host),
      isCanonicalPort(port)
    else {
      return nil
    }
    return ipv4AddressIsAllowed(octets)
  }

  private func directSocketAddressIsGloballyRoutable(_ value: String) -> Bool {
    if value.hasPrefix("["),
      let closingBracket = value.firstIndex(of: "]") {
      let host = String(value[value.index(after: value.startIndex)..<closingBracket])
      guard let bytes = ipv6LiteralBytes(host) else {
        return false
      }
      return ipv6AddressIsGloballyRoutable(bytes)
    }
    guard let separator = value.lastIndex(of: ":"),
      let octets = canonicalIPv4Octets(String(value[..<separator]))
    else {
      return false
    }
    return ipv4AddressIsGloballyRoutable(octets)
  }

  private func canonicalIPv4Octets(_ host: String) -> [UInt8]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else {
      return nil
    }
    let octets = parts.compactMap { part -> UInt8? in
      guard !part.isEmpty,
        part.utf8.allSatisfy({ (48...57).contains($0) }),
        let value = Int(part),
        (0...255).contains(value)
      else {
        return nil
      }
      guard String(value) == part else {
        return nil
      }
      return UInt8(value)
    }
    return octets.count == 4 ? octets : nil
  }

  private func ipv4AddressIsAllowed(_ octets: [UInt8]) -> Bool {
    guard octets.count == 4 else {
      return false
    }
    if octets[0] == 0 || octets[0] == 127 || (224...255).contains(octets[0]) {
      return false
    }
    // IPv4 link-local addresses need an interface scope just like IPv6
    // link-local addresses. This wire type cannot carry one, so no 169.254/16
    // address is safely dialable after serialization.
    if octets[0] == 169 && octets[1] == 254 {
      return false
    }
    return true
  }

  private func ipv4AddressIsGloballyRoutable(_ octets: [UInt8]) -> Bool {
    guard ipv4AddressIsAllowed(octets) else {
      return false
    }
    let first = octets[0]
    let second = octets[1]
    let third = octets[2]
    if first == 10
      || (first == 100 && (64...127).contains(second))
      || (first == 169 && second == 254)
      || (first == 172 && (16...31).contains(second))
      || (first == 192 && second == 168) {
      return false
    }
    if (first == 192 && second == 0 && third == 0)
      || (first == 192 && second == 0 && third == 2)
      || (first == 192 && second == 88 && third == 99)
      || (first == 198 && (second == 18 || second == 19))
      || (first == 198 && second == 51 && third == 100)
      || (first == 203 && second == 0 && third == 113) {
      return false
    }
    return true
  }

  private func ipv6LiteralIsAllowed(_ host: String) -> Bool? {
    guard let bytes = ipv6LiteralBytes(host) else {
      return nil
    }
    return ipv6AddressIsAllowed(bytes)
  }

  private func ipv6LiteralBytes(_ host: String) -> [UInt8]? {
    var address = in6_addr()
    let parsed = host.withCString { pointer in
      inet_pton(AF_INET6, pointer, &address)
    }
    guard parsed == 1 else {
      return nil
    }
    return withUnsafeBytes(of: &address) { Array($0) }
  }

  private func ipv6AddressIsAllowed(_ bytes: [UInt8]) -> Bool {
    if bytes.allSatisfy({ $0 == 0 }) || bytes == Array(repeating: 0, count: 15) + [1] {
      return false
    }
    if bytes.first == 0xFF {
      return false
    }
    // A serialized remote `%en0` scope is meaningless on the receiving
    // device, while an unscoped fe80::/10 address is not dialable. Local
    // discovery must construct any scoped link-local address in-process.
    if bytes.count == 16,
      bytes[0] == 0xFE,
      (bytes[1] & 0xC0) == 0x80 {
      return false
    }
    if bytes == [0xFD, 0x00, 0x0E, 0xC2]
      + Array(repeating: 0, count: 10)
      + [0x02, 0x54] {
      return false
    }
    let ipv4MappedPrefix = Array(repeating: UInt8(0), count: 10) + [0xFF, 0xFF]
    if Array(bytes.prefix(12)) == ipv4MappedPrefix {
      return ipv4AddressIsAllowed(Array(bytes.suffix(4)))
    }
    return true
  }

  private func ipv6AddressIsGloballyRoutable(_ bytes: [UInt8]) -> Bool {
    let ipv4MappedPrefix = Array(repeating: UInt8(0), count: 10) + [0xFF, 0xFF]
    if Array(bytes.prefix(12)) == ipv4MappedPrefix {
      return ipv4AddressIsGloballyRoutable(Array(bytes.suffix(4)))
    }
    guard bytes.count == 16,
      (bytes[0] & 0xE0) == 0x20
    else {
      return false
    }
    if bytes[0] == 0x20,
      bytes[1] == 0x01,
      bytes[2] <= 0x01 || (bytes[2] == 0x0D && bytes[3] == 0xB8) {
      return false
    }
    if bytes[0] == 0x20 && bytes[1] == 0x02 {
      return false
    }
    if bytes[0] == 0x3F && bytes[1] == 0xFF && (bytes[2] & 0xF0) == 0 {
      return false
    }
    return true
  }

  private func isCanonicalPort(_ port: String) -> Bool {
    guard !port.isEmpty,
      port.utf8.allSatisfy({ (48...57).contains($0) }),
      let value = Int(port),
      (1...65_535).contains(value)
    else {
      return false
    }
    return String(value) == port
  }

  private func isSafeRelayURL(_ value: String) -> Bool {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.count <= 2_048,
      value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      !value.contains("\\"),
      let components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      let host = components.host,
      relayHostIsAllowed(host),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else {
      return false
    }
    return components.port.map { (1...65_535).contains($0) } ?? true
  }

  private func relayHostIsAllowed(_ host: String) -> Bool {
    let normalized = host.lowercased()
    if let octets = canonicalIPv4Octets(normalized) {
      return ipv4AddressIsGloballyRoutable(octets)
    }
    if normalized.contains(":"),
      let bytes = ipv6LiteralBytes(normalized)
    {
      return ipv6AddressIsGloballyRoutable(bytes)
    }
    guard normalized.utf8.count <= 253,
      !normalized.hasSuffix("."),
      !normalized.hasSuffix(".localhost"),
      !normalized.hasSuffix(".local"),
      !normalized.hasSuffix(".home.arpa")
    else {
      return false
    }
    let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2,
      labels.allSatisfy({ dnsLabelIsAllowed($0) }),
      let topLevelLabel = labels.last,
      topLevelLabel.utf8.contains(where: { (97...122).contains($0) })
    else {
      return false
    }
    return true
  }

  private func dnsLabelIsAllowed(_ label: Substring) -> Bool {
    guard !label.isEmpty,
      label.utf8.count <= 63,
      let first = label.utf8.first,
      let last = label.utf8.last,
      isASCIILetterOrDigit(first),
      isASCIILetterOrDigit(last)
    else {
      return false
    }
    return label.utf8.allSatisfy { byte in
      isASCIILetterOrDigit(byte) || byte == 45
    }
  }

  private func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...122).contains(byte)
  }

  private func isSafeIdentifier(
    _ value: String,
    maximumUTF8Count: Int
  ) -> Bool {
    guard !value.isEmpty,
      value.utf8.count <= maximumUTF8Count
    else {
      return false
    }
    return value.utf8.allSatisfy { byte in
      (48...57).contains(byte)
        || (65...90).contains(byte)
        || (97...122).contains(byte)
        || byte == 45
        || byte == 46
        || byte == 58
        || byte == 95
    }
  }

  func validate(
    requireCurrentPrivateMetadata: Bool,
    requireSafeValueShape: Bool
  ) throws {
    let value = hint.value
    let kind = hint.kind
    let source = hint.source
    let privacyScope = hint.privacyScope
    let observedAt = hint.observedAt
    let expiresAt = hint.expiresAt
    let networkProfile = hint.networkProfile
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CmxIrohPathHintError.emptyValue
    }
    if requireSafeValueShape {
      switch kind {
      case .directAddress:
        guard let directAddressIsAllowed = directSocketAddressIsAllowed(value) else {
          throw CmxIrohPathHintError.invalidDirectAddress
        }
        guard directAddressIsAllowed else {
          throw CmxIrohPathHintError.forbiddenDirectAddress
        }
        if privacyScope == .publicInternet,
          !directSocketAddressIsGloballyRoutable(value)
        {
          throw CmxIrohPathHintError.nonGlobalPublicDirectAddress
        }
      case .relayIdentifier:
        guard isSafeIdentifier(value, maximumUTF8Count: 255) else {
          throw CmxIrohPathHintError.invalidRelayIdentifier
        }
      case .relayURL:
        guard isSafeRelayURL(value) else {
          throw CmxIrohPathHintError.unsafeRelayURL
        }
      }
    }
    if kind == .relayIdentifier || kind == .relayURL {
      guard source == .native, privacyScope == .publicInternet else {
        throw CmxIrohPathHintError.relayHintRequiresNativePublicSource
      }
    }
    switch source {
    case .native:
      let isInertLegacyPrivateHint = !requireCurrentPrivateMetadata
        && observedAt == nil
        && expiresAt == nil
        && networkProfile == nil
      guard privacyScope == .publicInternet || isInertLegacyPrivateHint else {
        throw CmxIrohPathHintError.incompatiblePrivacyScope(
          source: source,
          scope: privacyScope
        )
      }
    case .lan:
      guard privacyScope == .localNetwork else {
        throw CmxIrohPathHintError.incompatiblePrivacyScope(
          source: source,
          scope: privacyScope
        )
      }
    case .tailscale, .customVPN:
      guard privacyScope == .privateNetwork else {
        throw CmxIrohPathHintError.incompatiblePrivacyScope(
          source: source,
          scope: privacyScope
        )
      }
    }
    if privacyScope == .publicInternet {
      guard networkProfile == nil else {
        throw CmxIrohPathHintError.unexpectedPublicNetworkProfile
      }
      return
    }
    guard requireCurrentPrivateMetadata else {
      return
    }
    guard let observedAt else {
      throw CmxIrohPathHintError.missingPrivateHintObservation
    }
    guard let expiresAt else {
      throw CmxIrohPathHintError.missingPrivateHintExpiry
    }
    guard let networkProfile else {
      throw CmxIrohPathHintError.missingPrivateHintNetworkProfile
    }
    guard networkProfile.source == source else {
      throw CmxIrohPathHintError.networkProfileSourceMismatch
    }
    let lifetime = expiresAt.timeIntervalSince(observedAt)
    guard lifetime > 0 else {
      throw CmxIrohPathHintError.invalidPrivateHintLifetime
    }
    guard lifetime <= CmxIrohPathHint.maximumPrivateHintTTL else {
      throw CmxIrohPathHintError.privateHintTTLExceedsMaximum
    }
  }
}

extension CmxIrohPathHint {
  func validate(
    requireCurrentPrivateMetadata: Bool,
    requireSafeValueShape: Bool
  ) throws {
    try CmxIrohPathHintValidator(hint: self).validate(
      requireCurrentPrivateMetadata: requireCurrentPrivateMetadata,
      requireSafeValueShape: requireSafeValueShape
    )
  }
}
