import Foundation

/// A collaborator currently viewing the active workspace.
struct WorkspacePresenceParticipant: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String?
    let avatarURL: URL?
    let lastSeenAt: Date
}

/// Compact avatar-stack policy with deterministic overflow.
enum WorkspacePresencePolicy {
    static func layout(participants: [WorkspacePresenceParticipant], maximumVisible: Int = 4) -> (visible: [WorkspacePresenceParticipant], overflow: Int) {
        let limit = max(1, maximumVisible)
        return (Array(participants.prefix(limit)), max(0, participants.count - limit))
    }
}
