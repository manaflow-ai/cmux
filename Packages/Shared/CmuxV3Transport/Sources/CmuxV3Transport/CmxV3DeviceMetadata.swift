import Foundation

/// Signed discovery hints for an enrolled device, independent of authorization policy tags.
public struct CmxV3DeviceMetadata: Codable, Sendable {
    /// Operating system family advertised by the device.
    public enum Platform: String, Codable, Sendable {
        /// A macOS host.
        case mac
        /// An iOS client.
        case ios
        /// A Linux device.
        case linux
        /// A Windows device.
        case windows
    }
    /// The device operating system family.
    public let platform: Platform
    /// The real app instance tag, bounded to 128 ASCII bytes.
    public let instanceTag: String
    /// A nonempty user-visible name, bounded to 256 UTF-8 bytes.
    public let displayName: String
    /// Whether this Mac currently accepts pairing. Other platforms must use false.
    public let pairingEnabled: Bool
    /// The platform-prefixed actual app bundle namespace.
    public let clientNamespace: String

    /// Creates bounded device metadata matching the control authority's validation.
    ///
    /// - Parameters:
    ///   - platform: The device operating system family.
    ///   - instanceTag: The app's actual instance tag.
    ///   - displayName: The device name displayed in discovery.
    ///   - pairingEnabled: Whether this Mac accepts pairing.
    ///   - clientNamespace: The platform prefix followed by the actual bundle identifier.
    /// - Throws: An invalid-configuration error when metadata violates its bounds.
    public init(platform: Platform, instanceTag: String, displayName: String, pairingEnabled: Bool, clientNamespace: String) throws {
        let prefix = platform.rawValue + ":"
        let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let namespaceCharacters = identifierCharacters.union(CharacterSet(charactersIn: ":"))
        guard !instanceTag.isEmpty, instanceTag.utf8.count <= 128,
              instanceTag.unicodeScalars.allSatisfy(identifierCharacters.contains),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, displayName.utf8.count <= 256,
              !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              clientNamespace.utf8.count > prefix.utf8.count, clientNamespace.utf8.count <= 256,
              clientNamespace.hasPrefix(prefix), clientNamespace.unicodeScalars.allSatisfy(namespaceCharacters.contains),
              !pairingEnabled || platform == .mac else { throw CmxV3HTTPGrantError.invalidConfiguration }
        self.platform = platform
        self.instanceTag = instanceTag
        self.displayName = displayName
        self.pairingEnabled = pairingEnabled
        self.clientNamespace = clientNamespace
    }

    enum CodingKeys: String, CodingKey {
        case platform
        case instanceTag = "instance_tag"
        case displayName = "display_name"
        case pairingEnabled = "pairing_enabled"
        case clientNamespace = "client_namespace"
    }

    /// Decodes metadata with the same bounds enforced for local enrollment.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            platform: try values.decode(Platform.self, forKey: .platform),
            instanceTag: try values.decode(String.self, forKey: .instanceTag),
            displayName: try values.decode(String.self, forKey: .displayName),
            pairingEnabled: try values.decode(Bool.self, forKey: .pairingEnabled),
            clientNamespace: try values.decode(String.self, forKey: .clientNamespace)
        )
    }
}
