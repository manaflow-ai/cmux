public import CMUXMobileCore
public import Foundation

/// Endpoint-authenticated device state submitted to the Iroh trust broker.
public struct CmxIrohRegistrationPayload: Encodable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case routeContractVersion = "route_contract_version"
        case deviceID = "deviceId"
        case appInstanceID = "appInstanceId"
        case tag
        case platform
        case displayName
        case endpointID = "endpointId"
        case identityGeneration
        case pairingEnabled
        case capabilities
        case pathHints
        case directPorts
    }

    /// Current route-disclosure contract understood by the broker.
    public let routeContractVersion: Int
    /// Stable app-generated device UUID.
    public let deviceID: String
    /// Stable app-instance UUID for this installation and tag.
    public let appInstanceID: String
    /// Safe build or app-instance tag.
    public let tag: String
    /// Device role used by grant policy.
    public let platform: CmxIrohPlatform
    /// Optional user-facing device name.
    public let displayName: String?
    /// Canonical 64-character lowercase Iroh EndpointID.
    public let endpointID: String
    /// Generation changed only when endpoint identity rotates.
    public let identityGeneration: Int
    /// Whether this endpoint currently accepts pairing.
    public let pairingEnabled: Bool
    /// Bounded application capabilities advertised by this endpoint.
    public let capabilities: [String]
    /// Fresh reachability hints whose privacy scope remains explicit.
    public let pathHints: [CmxIrohPathHint]
    /// Endpoint-observed UDP ports, without any private IP address.
    public let directPorts: CmxIrohDirectPorts?

    /// Creates a payload matching the broker contract.
    ///
    /// - Throws: ``CmxIrohRegistrationError/invalidPayload`` for any value the
    ///   broker would reject or any stale/unsafe hint.
    public init(
        deviceID: String,
        appInstanceID: String,
        tag: String,
        platform: CmxIrohPlatform,
        displayName: String? = nil,
        endpointID: String,
        identityGeneration: Int,
        pairingEnabled: Bool,
        capabilities: [String],
        pathHints: [CmxIrohPathHint],
        directPorts: CmxIrohDirectPorts? = nil,
        now: Date = Date()
    ) throws {
        guard Self.isBrokerUUID(deviceID),
              Self.isBrokerUUID(appInstanceID),
              Self.isSafeToken(tag, maximum: 64),
              (try? CmxIrohPeerIdentity(endpointID: endpointID)) != nil,
              (1...Int(Int32.max)).contains(identityGeneration),
              capabilities.count <= 32,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy({ Self.isSafeToken($0, maximum: 64) }),
              pathHints.count <= 16,
              pathHints.filter({ $0.kind == .relayURL }).count <= 2,
              pathHints.allSatisfy({ Self.isBrokerHint($0, now: now) }) else {
            throw CmxIrohRegistrationError.invalidPayload
        }
        if let displayName {
            guard !displayName.isEmpty,
                  displayName.utf16.count <= 128,
                  !displayName.unicodeScalars.contains(where: {
                      $0.value <= 0x1f || $0.value == 0x7f
                  }) else {
                throw CmxIrohRegistrationError.invalidPayload
            }
        }
        routeContractVersion = 1
        self.deviceID = cmxCanonicalDeviceID(deviceID)
        self.appInstanceID = appInstanceID.lowercased()
        self.tag = tag
        self.platform = platform
        self.displayName = displayName
        self.endpointID = endpointID
        self.identityGeneration = identityGeneration
        self.pairingEnabled = pairingEnabled
        self.capabilities = capabilities
        self.pathHints = pathHints
        self.directPorts = directPorts
    }

    private static func isBrokerUUID(_ value: String) -> Bool {
        let bytes = Array(value.lowercased().utf8)
        guard bytes.count == 36,
              bytes[8] == 45,
              bytes[13] == 45,
              bytes[18] == 45,
              bytes[23] == 45,
              (49...56).contains(bytes[14]),
              [56, 57, 97, 98].contains(bytes[19]) else {
            return false
        }
        return bytes.enumerated().allSatisfy { index, byte in
            if [8, 13, 18, 23].contains(index) {
                return byte == 45
            }
            return (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isSafeToken(_ value: String, maximum: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximum else {
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

    private static func isBrokerHint(_ hint: CmxIrohPathHint, now: Date) -> Bool {
        guard hint.kind != .relayIdentifier,
              hint.isSafeForCurrentWireFormat,
              hint.isUsable(at: now),
              let observedAt = hint.observedAt,
              let expiresAt = hint.expiresAt,
              observedAt <= now.addingTimeInterval(5 * 60),
              observedAt >= now.addingTimeInterval(-60 * 60),
              expiresAt > now,
              expiresAt <= observedAt.addingTimeInterval(60 * 60) else {
            return false
        }
        return true
    }
}
