import Foundation

public enum CMUXExtensionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case sidebar
}

public struct CMUXExtensionManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: CMUXExtensionKind
    public var minimumAPIVersion: CMUXExtensionAPIVersion
    public var requestedScopes: [CMUXExtensionScope]

    public init(
        id: String,
        displayName: String,
        kind: CMUXExtensionKind = .sidebar,
        minimumAPIVersion: CMUXExtensionAPIVersion = .sidebarV1,
        requestedScopes: [CMUXExtensionScope] = [.workspaceMetadata]
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.minimumAPIVersion = minimumAPIVersion
        self.requestedScopes = requestedScopes
    }
}

public enum CMUXExtensionScope: String, Codable, CaseIterable, Equatable, Sendable {
    case workspaceMetadata
    case workspacePaths
    case notifications
    case networkPorts
    case pullRequests
}
