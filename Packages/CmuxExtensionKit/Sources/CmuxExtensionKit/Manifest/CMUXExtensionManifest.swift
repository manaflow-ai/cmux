import Foundation

public struct CmuxExtensionManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    @_spi(CmuxHostTransport) public var minimumAPIVersion: CmuxExtensionAPIVersion
    public var readScopes: [CmuxExtensionScope]
    public var actionScopes: [CmuxExtensionActionScope]

    public init(
        id: String,
        displayName: String,
        readScopes: [CmuxExtensionScope] = [],
        actionScopes: [CmuxExtensionActionScope] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.minimumAPIVersion = .sidebarV1
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
        minimumAPIVersion = try container.decodeIfPresent(CmuxExtensionAPIVersion.self, forKey: .minimumAPIVersion) ?? .sidebarV1
        readScopes = try container.decode([CmuxExtensionScope].self, forKey: .readScopes)
        actionScopes = try container.decodeIfPresent(
            [CmuxExtensionActionScope].self,
            forKey: .actionScopes
        ) ?? []
    }
}
