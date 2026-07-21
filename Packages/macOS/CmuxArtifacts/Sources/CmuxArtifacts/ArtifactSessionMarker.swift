import Foundation

/// Small cmux-managed identity marker stored in a capture session folder.
struct ArtifactSessionMarker: Codable, Equatable, Sendable {
    let sessionID: String?
    let agentName: String?
    let createdAt: Date
}
