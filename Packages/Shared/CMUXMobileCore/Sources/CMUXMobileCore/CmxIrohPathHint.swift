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
