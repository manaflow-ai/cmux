import Foundation

public enum CMUXExtensionScope: String, Codable, CaseIterable, Equatable, Sendable {
    case workspaceMetadata
    case workspacePaths
    case notifications
    case networkPorts
    case pullRequests
}
