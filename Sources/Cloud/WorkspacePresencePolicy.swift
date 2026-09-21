import Foundation

/// A collaborator currently viewing one workspace/thread.
struct WorkspacePresenceParticipant: Identifiable, Equatable, Sendable {
    let id: String
    let viewerID: String?
    let displayName: String?
    let avatarURL: URL?
    let deviceID: String
    let tag: String
    let lastSeenAt: Date
}

/// The compact rendering budget for the right-sidebar collaborator strip.
struct WorkspacePresenceAvatarLayout: Equatable, Sendable {
    let visible: [WorkspacePresenceParticipant]
    let overflowCount: Int
}

enum WorkspacePresencePolicy {
    static func participants(
        from instances: some Sequence<WorkspacePresenceParticipant>,
        currentViewerID: String?
    ) -> [WorkspacePresenceParticipant] {
        var newestByViewer: [String: WorkspacePresenceParticipant] = [:]
        for participant in instances where participant.lastSeenAt.timeIntervalSince1970 >= 0 {
            let key = participant.viewerID.map { "viewer:\($0)" }
                ?? "instance:\(participant.deviceID):\(participant.tag)"
            if let currentViewerID,
               participant.viewerID == currentViewerID {
                continue
            }
            if let existing = newestByViewer[key], existing.lastSeenAt >= participant.lastSeenAt {
                continue
            }
            newestByViewer[key] = participant
        }
        return newestByViewer.values.sorted {
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            return $0.id < $1.id
        }
    }

    static func avatarLayout(
        participants: [WorkspacePresenceParticipant],
        maximumVisible: Int = 4
    ) -> WorkspacePresenceAvatarLayout {
        let limit = max(1, maximumVisible)
        return WorkspacePresenceAvatarLayout(
            visible: Array(participants.prefix(limit)),
            overflowCount: max(0, participants.count - limit)
        )
    }
}
