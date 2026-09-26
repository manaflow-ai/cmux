import CmuxWorkspacePresence
import Foundation

/// Compact avatar-stack policy with deterministic overflow.
struct WorkspacePresencePolicy {
    static func layout(participants: [WorkspacePresenceParticipant], maximumVisible: Int = 4) -> (visible: [WorkspacePresenceParticipant], overflow: Int) {
        let limit = max(1, maximumVisible)
        return (Array(participants.prefix(limit)), max(0, participants.count - limit))
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
