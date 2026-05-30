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
        requestedScopes: [CMUXExtensionScope] = [.workspaceMetadata],
        requestedActionScopes: [CMUXExtensionActionScope] = [.selectWorkspace]
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
            requestedActionScopes: [.selectWorkspace]
        )
    }
}
