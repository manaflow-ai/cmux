import Foundation

/// Small cmux-managed identity marker stored in a capture workspace folder.
struct ArtifactWorkspaceMarker: Codable, Equatable, Sendable {
    let workspaceID: String?
    let workspaceTitle: String?
    let createdAt: Date
}
