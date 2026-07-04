import Foundation

/// Who set the workspace `customDescription`.
enum WorkspaceCustomDescriptionSource: String, Codable, Sendable {
    case user
    case agent
}
