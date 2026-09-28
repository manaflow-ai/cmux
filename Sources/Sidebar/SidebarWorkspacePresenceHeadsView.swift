import AppKit
import CmuxWorkspacePresence
import SwiftUI

/// Renders the compact collaborator heads attached to a Cloud workspace row.
struct SidebarWorkspacePresenceHeadsView: View {
    let participants: [WorkspacePresenceParticipant]

    var body: some View {
        let layout = WorkspacePresencePolicy.layout(participants: participants)
        HStack(spacing: 2) {
            HStack(spacing: -5) {
                ForEach(layout.visible) { participant in
                    StackAccountAvatarView(
                        avatarURL: participant.avatarURL,
                        displayName: participant.displayName ?? "",
                        email: "",
                        size: 18
                    )
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.25))
                }
            }
            if layout.overflow > 0 {
                Text(verbatim: "+\(layout.overflow)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
        .help(WorkspacePresencePolicy.names(participants))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WorkspacePresencePolicy.accessibilityLabel(participants))
    }
}
