import Foundation

/// One approval request tracked within a Codex runtime generation.
struct CodexPermissionRequest: Codable, Equatable, Sendable {
    var identity: CodexPermissionSignalIdentity
    var notificationID: UUID?
    var blocksInput: Bool
}
