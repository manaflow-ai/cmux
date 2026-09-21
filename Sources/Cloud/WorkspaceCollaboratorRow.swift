import SwiftUI

/// One collaborator row in the expanded workspace presence popover.
struct WorkspaceCollaboratorRow: View {
    let participant: WorkspacePresenceParticipant

    var body: some View {
        HStack(spacing: 8) {
            StackAccountAvatarView(
                avatarURL: participant.avatarURL,
                displayName: participant.displayName ?? String(localized: "rightSidebar.presence.anonymous", defaultValue: "Anonymous collaborator"),
                email: "",
                size: 24
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(participant.displayName ?? String(localized: "rightSidebar.presence.anonymous", defaultValue: "Anonymous collaborator"))
                    .font(.callout)
                    .lineLimit(1)
                Text(String(localized: "rightSidebar.presence.activeNow", defaultValue: "Active now"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
