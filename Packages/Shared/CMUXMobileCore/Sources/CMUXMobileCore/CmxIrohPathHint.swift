import Darwin
import Foundation

/// A provider-attributed, privacy-scoped address hint for an Iroh peer.
///
/// Hints influence reachability only. They never establish peer identity or
/// authorize credentials. Non-public hints are fallback-only by construction
/// and newly created private hints must expire.
public struct CmxIrohPathHint: Equatable, Sendable {
    /// The longest lifetime accepted for any non-public hint.
    public static let maximumPrivateHintTTL: TimeInterval = 60 * 60

    /// The clock skew tolerated when comparing a provider observation with the
    /// local clock. A larger future offset makes the hint inert instead of
    /// extending its usable lifetime.
    public static let maximumObservationClockSkew: TimeInterval = 5 * 60

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case source
        case privacyScope = "privacy_scope"
        case observedAt = "observed_at"
        case expiresAt = "expires_at"
        case networkProfile = "network_profile"
        case legacyNetworkProfileID = "network_profile_id"
    }

    /// The address form carried by the hint.
    public let kind: CmxIrohPathHintKind
    /// The socket address, relay identifier, or relay URL.
    public let value: String
    /// The provider that discovered the hint.
    public let source: CmxIrohPathHintSource
    /// The network scope in which the hint may be disclosed.
    public let privacyScope: CmxIrohPathHintPrivacyScope
    /// When the provider last observed this path.
    public let observedAt: Date?
    /// The time after which the hint must no longer be attempted.
    public let expiresAt: Date?
    /// The provider-qualified overlay, site, or network profile.
    ///
    /// This disambiguates overlapping private address spaces. It is routing
    /// metadata only and never contributes to peer authentication.
    public let networkProfile: CmxIrohNetworkProfileKey?

    /// Creates a validated Iroh path hint.
    ///
    /// Every non-public hint requires an observation time, an expiry no more
    /// than one hour later, and a provider-qualified active-network profile.
    /// Older hints missing those fields decode only through the internal inert
    /// compatibility path and remain unusable until refreshed.
    /// - Parameters:
    ///   - kind: The address form carried by the hint.
    ///   - value: The socket address, relay identifier, or relay URL.
    ///   - source: The provider that discovered the hint.
    ///   - privacyScope: The narrowest scope in which it may be disclosed.
    ///   - observedAt: When the provider observed the path.
    ///   - expiresAt: The time after which the hint must not be attempted.
    ///   - networkProfile: The provider-qualified active-network profile.
    /// - Throws: ``CmxIrohPathHintError`` when the hint violates its invariants.
    public init(
        kind: CmxIrohPathHintKind,
        value: String,
        source: CmxIrohPathHintSource,
        privacyScope: CmxIrohPathHintPrivacyScope,
        observedAt: Date? = nil,
        expiresAt: Date? = nil,
        networkProfile: CmxIrohNetworkProfileKey? = nil
    ) throws {
        self.kind = kind
        self.value = value
        self.source = source
        self.privacyScope = privacyScope
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.networkProfile = networkProfile
        try validate(requireCurrentPrivateMetadata: true, requireSafeValueShape: true)
    }

    /// The routing tier derived from privacy scope.
    ///
    /// Callers cannot promote a private-network address to a primary path.
    public var use: CmxIrohPathHintUse {
        privacyScope == .publicInternet ? .primary : .fallbackOnly
    }

    /// Whether the hint may be attempted at a given time.
    ///
    /// Legacy private hints without an expiry decode for compatibility but are
    /// deliberately inert until a current producer replaces them.
    /// - Parameter now: The time against which expiry is checked.
    /// - Returns: `true` when the hint is current and usable.
    public func isUsable(at now: Date) -> Bool {
        guard isSafeForCurrentWireFormat else {
            return false
        }
        if let observedAt,
           observedAt > now.addingTimeInterval(Self.maximumObservationClockSkew) {
            return false
        }
        if privacyScope != .publicInternet {
            guard let expiresAt,
                  expiresAt <= now.addingTimeInterval(
                      Self.maximumPrivateHintTTL + Self.maximumObservationClockSkew
                  ) else {
                return false
            }
        }
        if let expiresAt {
            return expiresAt > now
        }
        return privacyScope == .publicInternet
    }

    /// A public-disclosure copy, or `nil` when this hint is private, local,
    /// expired, or structurally unsafe.
    public func publicDisclosure(at now: Date) -> Self? {
        guard privacyScope == .publicInternet, isUsable(at: now) else {
            return nil
        }
        return try? Self(
            kind: kind,
            value: value,
            source: source,
            privacyScope: privacyScope,
            observedAt: observedAt,
            expiresAt: expiresAt,
            networkProfile: nil
        )
    }

    /// Revalidates structural relationships while tolerating inert legacy data.
    func validate() throws {
        try validate(requireCurrentPrivateMetadata: false, requireSafeValueShape: false)
    }

    /// Whether the hint satisfies the current value, privacy, and expiry rules.
    ///
    /// Legacy fields may decode without satisfying this predicate so old
    /// tickets remain readable, but those hints must not be attempted or
    /// re-emitted into a format that would promote them.
    public var isSafeForCurrentWireFormat: Bool {
        do {
            try validate(requireCurrentPrivateMetadata: true, requireSafeValueShape: true)
            return true
        } catch {
            return false
        }
    }

    /// Builds an inert compatibility hint from the pre-provenance wire fields.
    static func legacy(
        kind: CmxIrohPathHintKind,
        value: String,
        privacyScope: CmxIrohPathHintPrivacyScope
    ) -> Self {
        Self(
            legacyKind: kind,
            value: value,
            privacyScope: privacyScope
        )
    }

    private init(
        legacyKind kind: CmxIrohPathHintKind,
        value: String,
        privacyScope: CmxIrohPathHintPrivacyScope
    ) {
        self.init(
            rawKind: kind,
            value: value,
            source: .native,
            privacyScope: privacyScope,
            observedAt: nil,
            expiresAt: nil,
            networkProfile: nil
        )
    }

    private init(
        rawKind kind: CmxIrohPathHintKind,
        value: String,
        source: CmxIrohPathHintSource,
        privacyScope: CmxIrohPathHintPrivacyScope,
        observedAt: Date?,
        expiresAt: Date?,
        networkProfile: CmxIrohNetworkProfileKey?
    ) {
        self.kind = kind
        self.value = value
        self.source = source
        self.privacyScope = privacyScope
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.networkProfile = networkProfile
    }

    private func validate(
        requireCurrentPrivateMetadata: Bool,
        requireSafeValueShape: Bool
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CmxIrohPathHintError.emptyValue
        }

        if requireSafeValueShape {
            switch kind {
            case .directAddress:
                guard let directAddressIsAllowed = Self.directSocketAddressIsAllowed(value) else {
                    throw CmxIrohPathHintError.invalidDirectAddress
                }
                guard directAddressIsAllowed else {
                    throw CmxIrohPathHintError.forbiddenDirectAddress
                }
                if privacyScope == .publicInternet,
                   !Self.directSocketAddressIsGloballyRoutable(value) {
                    throw CmxIrohPathHintError.nonGlobalPublicDirectAddress
                }
            case .relayIdentifier:
                guard Self.isSafeIdentifier(value, maximumUTF8Count: 255) else {
                    throw CmxIrohPathHintError.invalidRelayIdentifier
                }
            case .relayURL:
                guard Self.isSafeRelayURL(value) else {
                    throw CmxIrohPathHintError.unsafeRelayURL
                }
            }
        }

        switch source {
        case .native:
            break
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

        if kind == .relayIdentifier || kind == .relayURL {
            guard source == .native, privacyScope == .publicInternet else {
                throw CmxIrohPathHintError.relayHintRequiresNativePublicSource
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
        guard lifetime <= Self.maximumPrivateHintTTL else {
            throw CmxIrohPathHintError.privateHintTTLExceedsMaximum
        }
    }

    /// Returns `nil` for malformed socket syntax, otherwise whether the IP is
    /// allowed as a remote Iroh peer address.
    private static func directSocketAddressIsAllowed(_ value: String) -> Bool? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 80,
              !value.contains("/"),
              !value.contains("@"),
              !value.contains("?") && !value.contains("#") else {
            return nil
        }

        if value.hasPrefix("[") {
            guard let closingBracket = value.firstIndex(of: "]"),
                  value.index(after: closingBracket) < value.endIndex,
                  value[value.index(after: closingBracket)] == ":" else {
                return nil
            }
            let host = String(value[value.index(after: value.startIndex)..<closingBracket])
            let portStart = value.index(closingBracket, offsetBy: 2)
            let port = String(value[portStart...])
            guard !host.contains("%"),
                  let addressIsAllowed = ipv6LiteralIsAllowed(host),
                  isCanonicalPort(port) else {
                return nil
            }
            return addressIsAllowed
        }

        guard let separator = value.lastIndex(of: ":"),
              value[..<separator].contains(":") == false else {
            return nil
        }
        let host = String(value[..<separator])
        let port = String(value[value.index(after: separator)...])
        guard let octets = canonicalIPv4Octets(host),
              isCanonicalPort(port) else {
            return nil
        }
        return ipv4AddressIsAllowed(octets)
    }

    private static func directSocketAddressIsGloballyRoutable(_ value: String) -> Bool {
        if value.hasPrefix("["),
           let closingBracket = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<closingBracket])
            guard let bytes = ipv6LiteralBytes(host) else {
                return false
            }
            return ipv6AddressIsGloballyRoutable(bytes)
        }

        guard let separator = value.lastIndex(of: ":"),
              let octets = canonicalIPv4Octets(String(value[..<separator])) else {
            return false
        }
        return ipv4AddressIsGloballyRoutable(octets)
    }

    private static func canonicalIPv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }
        let octets = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part),
                  (0...255).contains(value) else {
                return nil
            }
            guard String(value) == part else {
                return nil
            }
            return UInt8(value)
        }
        return octets.count == 4 ? octets : nil
    }

    private static func ipv4AddressIsAllowed(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else {
            return false
        }
        if octets[0] == 0 || octets[0] == 127 || (224...255).contains(octets[0]) {
            return false
        }
        if octets == [169, 254, 169, 254] {
            return false
        }
        return true
    }

    private static func ipv4AddressIsGloballyRoutable(_ octets: [UInt8]) -> Bool {
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

    private static func ipv6LiteralIsAllowed(_ host: String) -> Bool? {
        guard let bytes = ipv6LiteralBytes(host) else {
            return nil
        }
        return ipv6AddressIsAllowed(bytes)
    }

    private static func ipv6LiteralBytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let parsed = host.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard parsed == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func ipv6AddressIsAllowed(_ bytes: [UInt8]) -> Bool {
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

    private static func ipv6AddressIsGloballyRoutable(_ bytes: [UInt8]) -> Bool {
        let ipv4MappedPrefix = Array(repeating: UInt8(0), count: 10) + [0xFF, 0xFF]
        if Array(bytes.prefix(12)) == ipv4MappedPrefix {
            return ipv4AddressIsGloballyRoutable(Array(bytes.suffix(4)))
        }
        guard bytes.count == 16,
              (bytes[0] & 0xE0) == 0x20 else {
            return false
        }
        if bytes[0] == 0x20,
           bytes[1] == 0x01,
           (bytes[2] <= 0x01 || (bytes[2] == 0x0D && bytes[3] == 0xB8)) {
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

    private static func isCanonicalPort(_ port: String) -> Bool {
        guard !port.isEmpty,
              port.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(port),
              (1...65_535).contains(value) else {
            return false
        }
        return String(value) == port
    }

    private static func isSafeRelayURL(_ value: String) -> Bool {
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
              components.path.isEmpty || components.path == "/" else {
            return false
        }
        return components.port.map { (1...65_535).contains($0) } ?? true
    }

    private static func relayHostIsAllowed(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if let octets = canonicalIPv4Octets(normalized) {
            return ipv4AddressIsGloballyRoutable(octets)
        }
        if normalized.contains(":"),
           let bytes = ipv6LiteralBytes(normalized) {
            return ipv6AddressIsGloballyRoutable(bytes)
        }
        guard normalized.utf8.count <= 253,
              !normalized.hasSuffix("."),
              !normalized.hasSuffix(".localhost"),
              !normalized.hasSuffix(".local"),
              !normalized.hasSuffix(".home.arpa") else {
            return false
        }
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ dnsLabelIsAllowed($0) }),
              let topLevelLabel = labels.last,
              topLevelLabel.utf8.contains(where: { (97...122).contains($0) }) else {
            return false
        }
        return true
    }

    private static func dnsLabelIsAllowed(_ label: Substring) -> Bool {
        guard !label.isEmpty,
              label.utf8.count <= 63,
              let first = label.utf8.first,
              let last = label.utf8.last,
              isASCIILetterOrDigit(first),
              isASCIILetterOrDigit(last) else {
            return false
        }
        return label.utf8.allSatisfy { byte in
            isASCIILetterOrDigit(byte) || byte == 45
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }

    private static func isSafeIdentifier(
        _ value: String,
        maximumUTF8Count: Int
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Count else {
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
}

extension CmxIrohPathHint: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(CmxIrohPathHintKind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        let source = try container.decode(CmxIrohPathHintSource.self, forKey: .source)
        let privacyScope = try container.decode(CmxIrohPathHintPrivacyScope.self, forKey: .privacyScope)
        let observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        let expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        let networkProfile: CmxIrohNetworkProfileKey?
        if let current = try container.decodeIfPresent(
            CmxIrohNetworkProfileKey.self,
            forKey: .networkProfile
        ) {
            networkProfile = current
        } else if let legacyID = try container.decodeIfPresent(
            String.self,
            forKey: .legacyNetworkProfileID
        ) {
            networkProfile = try CmxIrohNetworkProfileKey(source: source, profileID: legacyID)
        } else {
            networkProfile = nil
        }

        if privacyScope == .publicInternet
            || (observedAt != nil && expiresAt != nil && networkProfile != nil) {
            try self.init(
                kind: kind,
                value: value,
                source: source,
                privacyScope: privacyScope,
                observedAt: observedAt,
                expiresAt: expiresAt,
                networkProfile: networkProfile
            )
        } else {
            // Compatibility with the first provenance-aware wire revision.
            // Missing freshness/profile metadata remains readable but inert,
            // and endpoint encoders prune it instead of re-emitting it.
            self.init(
                rawKind: kind,
                value: value,
                source: source,
                privacyScope: privacyScope,
                observedAt: observedAt,
                expiresAt: expiresAt,
                networkProfile: networkProfile
            )
            try validate()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(value, forKey: .value)
        try container.encode(source, forKey: .source)
        try container.encode(privacyScope, forKey: .privacyScope)
        try container.encodeIfPresent(observedAt, forKey: .observedAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(networkProfile, forKey: .networkProfile)
    }
}
