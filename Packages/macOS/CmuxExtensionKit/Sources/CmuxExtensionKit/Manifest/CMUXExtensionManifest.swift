import Foundation

/// Metadata and permission request declared by a CMUX extension.
public struct CmuxExtensionManifest: Codable, Equatable, Identifiable, Sendable {
    /// Stable reverse-DNS style identifier for the extension.
    public var id: String

    /// Human-readable extension name shown by CMUX permission and management UI.
    public var displayName: String

    /// Minimum CMUX extension API version required by this extension.
    @_spi(CmuxHostTransport) public var minimumAPIVersion: CmuxExtensionAPIVersion

    /// Sidebar data scopes the extension asks CMUX to include in snapshots.
    public var readScopes: [CmuxExtensionScope]

    /// Host action scopes the extension asks CMUX to allow.
    public var actionScopes: [CmuxExtensionActionScope]

    /// Whether this transport acknowledges pushed snapshots; absent in legacy SDKs.
    @_spi(CmuxHostTransport) public var supportsSnapshotAcknowledgement: Bool = false

    /// Creates a sidebar extension manifest.
    ///
    /// - Parameters:
    ///   - id: Stable reverse-DNS extension identifier.
    ///   - displayName: Name shown in host permission and management UI.
    ///   - readScopes: Data permissions requested from CMUX; none by default.
    ///   - actionScopes: Action permissions requested from CMUX; none by default.
    ///   - minimumAPIVersion: Required host API; new extensions require sidebar 2.2.
    public init(
        id: String,
        displayName: String,
        readScopes: [CmuxExtensionScope] = [],
        actionScopes: [CmuxExtensionActionScope] = [],
        minimumAPIVersion: CmuxExtensionAPIVersion = .sidebarV2_3
    ) {
        self.id = id
        self.displayName = displayName
        self.minimumAPIVersion = minimumAPIVersion
        self.readScopes = readScopes
        self.actionScopes = actionScopes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case minimumAPIVersion
        case readScopes
        case actionScopes
        case supportsSnapshotAcknowledgement
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        supportsSnapshotAcknowledgement = try container.decodeIfPresent(Bool.self, forKey: .supportsSnapshotAcknowledgement) ?? false
        minimumAPIVersion = try container.decodeIfPresent(CmuxExtensionAPIVersion.self, forKey: .minimumAPIVersion) ?? .sidebarV2_3
        readScopes = try container.decode([CmuxExtensionScope].self, forKey: .readScopes)
        actionScopes = try container.decodeIfPresent(
            [CmuxExtensionActionScope].self,
            forKey: .actionScopes
        ) ?? []
    }
}
