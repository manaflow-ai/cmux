import Foundation

public struct CMUXExtensionManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: CMUXExtensionKind
    public var minimumAPIVersion: CMUXExtensionAPIVersion
    public var requestedScopes: [CMUXExtensionScope]
    public var requestedActionScopes: [CMUXExtensionActionScope]

    public init(
        id: String,
        displayName: String,
        kind: CMUXExtensionKind = .sidebar,
        minimumAPIVersion: CMUXExtensionAPIVersion = .sidebarV1,
        requestedScopes: [CMUXExtensionScope] = [],
        requestedActionScopes: [CMUXExtensionActionScope] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.minimumAPIVersion = minimumAPIVersion
        self.requestedScopes = requestedScopes
        self.requestedActionScopes = requestedActionScopes
    }

    public init(
        id: String,
        displayName: String,
        kind: CMUXExtensionKind = .sidebar,
        minimumAPIVersion: CMUXExtensionAPIVersion = .sidebarV1,
        requestedScopes: [CMUXExtensionScope]
    ) {
        self.init(
            id: id,
            displayName: displayName,
            kind: kind,
            minimumAPIVersion: minimumAPIVersion,
            requestedScopes: requestedScopes,
            requestedActionScopes: []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case kind
        case minimumAPIVersion
        case requestedScopes
        case requestedActionScopes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(CMUXExtensionKind.self, forKey: .kind)
        minimumAPIVersion = try container.decode(CMUXExtensionAPIVersion.self, forKey: .minimumAPIVersion)
        requestedScopes = try container.decode([CMUXExtensionScope].self, forKey: .requestedScopes)
        requestedActionScopes = try container.decodeIfPresent(
            [CMUXExtensionActionScope].self,
            forKey: .requestedActionScopes
        ) ?? []
    }
}
