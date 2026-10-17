import Foundation

/// A bounded projection of one existing remote route; it carries no endpoint or execution authority.
public nonisolated struct MachineCatalogRecord: Encodable, Sendable, Equatable {
    /// How the app already reaches the owner; it does not select or create a carrier.
    public enum Origin: String, Encodable, Sendable {
        /// A Cloud route already in the registry.
        case cloud
        /// An existing SSH route.
        case ssh
        /// An existing paired-server route.
        case server
    }
    /// Availability of the existing carrier, without an implicit reconnect.
    public enum Status: String, Encodable, Sendable {
        /// The carrier completed its owner handshake.
        case running
        /// No admitted carrier is ready.
        case unavailable
    }
    /// Canonical owner identity, never a provider or UI alias.
    public let id: ResourceID
    /// A bounded non-secret display label.
    public let name: String
    /// Existing route kind.
    public let origin: Origin
    /// Existing carrier availability.
    public let status: Status
    /// Platform observed from that owner's handshake, nil on older owners.
    public let platform: MachineCatalogPlatform?
    /// Bounded machine-level capability tokens; these grant no execution rights.
    public let capabilities: [String]

    /// Creates a projection only for a canonical public machine ID.
    /// Display labels are bounded and stripped of controls; malformed metadata stays unknown.
    /// - Parameters:
    ///   - id: The observed `machine_` identity with 32 lowercase hexadecimal digits.
    ///   - name: The registry's display label, defaulting to the public ID if empty.
    ///   - origin: The existing carrier kind.
    ///   - status: That carrier's observed state.
    ///   - platform: That owner's optional observed platform.
    ///   - capabilities: That owner's observed machine capabilities, separate from protocol features.
    public init?(id: ResourceID, name: String, origin: Origin, status: Status,
                 platform: MachineCatalogPlatform? = nil, capabilities: [String] = []) {
        let raw = id.rawValue
        guard Self.validID(id) else { return nil }
        self.id = id
        let label = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(64)))
        self.name = label.isEmpty ? raw : String(label)
        self.origin = origin
        self.status = status
        self.platform = platform?.bounded
        var seen = Set<String>()
        self.capabilities = capabilities.prefix(64).filter { value in
            guard let first = value.utf8.first, (97...122).contains(first), (1...64).contains(value.utf8.count),
                  value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }) else { return false }
            return seen.insert(value).inserted
        }.prefix(16).map { $0 }
    }
    package static func validID(_ id: ResourceID) -> Bool {
        let raw = id.rawValue
        return raw.hasPrefix("machine_") && raw.utf8.count == 40 && raw.dropFirst(8).utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
