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

    /// Creates a sidebar extension manifest.
    public init(
        id: String,
        displayName: String,
        readScopes: [CmuxExtensionScope] = [],
        actionScopes: [CmuxExtensionActionScope] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.minimumAPIVersion = .sidebarV2
        self.readScopes = readScopes
        self.actionScopes = actionScopes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case minimumAPIVersion
        case readScopes
        case actionScopes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        minimumAPIVersion = try container.decodeIfPresent(CmuxExtensionAPIVersion.self, forKey: .minimumAPIVersion) ?? .sidebarV2
        readScopes = try container.decode([CmuxExtensionScope].self, forKey: .readScopes)
        actionScopes = try container.decodeIfPresent(
            [CmuxExtensionActionScope].self,
            forKey: .actionScopes
        ) ?? []
    }
}
