import CmuxWorkspacePresence
import Foundation

/// Compact avatar-stack policy with deterministic overflow.
struct WorkspacePresencePolicy {
    static let inactiveOpacity = 0.42

    /// Shows focused collaborators first while preserving source order within each activity group.
    static func layout(participants: [WorkspacePresenceParticipant], maximumVisible: Int = 4) -> (visible: [WorkspacePresenceParticipant], overflow: Int) {
        let limit = max(1, maximumVisible)
        var active: [WorkspacePresenceParticipant] = []
        var inactive: [WorkspacePresenceParticipant] = []
        active.reserveCapacity(limit)
        inactive.reserveCapacity(limit)
        for participant in participants {
            if participant.isActive {
                if active.count < limit { active.append(participant) }
            } else if inactive.count < limit {
                inactive.append(participant)
            }
        }
        var visible = Array(active.prefix(limit))
        if visible.count < limit {
            visible.append(contentsOf: inactive.prefix(limit - visible.count))
        }
        return (visible, max(0, participants.count - limit))
    }

    /// Returns full opacity for focused participants and a muted opacity for passive viewers.
    static func avatarOpacity(for participant: WorkspacePresenceParticipant) -> Double {
        participant.isActive ? 1 : inactiveOpacity
    }

    static func names(_ participants: [WorkspacePresenceParticipant]) -> String {
        participants.map {
            $0.displayName ?? String(localized: "rightSidebar.presence.anonymous", defaultValue: "Anonymous collaborator")
        }.joined(separator: ", ")
    }

    static func accessibilityLabel(_ participants: [WorkspacePresenceParticipant]) -> String {
        [String(localized: "rightSidebar.presence.title", defaultValue: "Viewing this workspace"), names(participants)]
            .joined(separator: ": ")
    }
}
