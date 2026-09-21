import SwiftUI

struct WorkspaceCollaboratorsView: View {
    let presence: WorkspacePresenceController
    @State private var expanded = false
    var body: some View {
        let participants = presence.collaborators()
        Button { expanded.toggle() } label: {
            if presence.activeScope == nil {
                Label(String(localized: "rightSidebar.presence.localOnly", defaultValue: "Local only"), systemImage: "person")
            } else if presence.phase != .available {
                Label(String(localized: "rightSidebar.presence.unavailable", defaultValue: "Presence unavailable"), systemImage: "person.2.slash")
            } else if participants.isEmpty {
                Label(String(localized: "rightSidebar.presence.onlyYou", defaultValue: "Only you"), systemImage: "person")
            } else {
                let stack = WorkspacePresencePolicy.layout(participants: participants)
                HStack(spacing: 4) {
                    HStack(spacing: -5) { ForEach(stack.visible) { participant in
                        StackAccountAvatarView(avatarURL: participant.avatarURL, displayName: participant.displayName ?? "", email: "", size: 19).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    }}
                    if stack.overflow > 0 { Text("+\(stack.overflow)").font(.caption2.weight(.semibold)) }
                }
            }
        }.buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary).popover(isPresented: $expanded) { WorkspaceCollaboratorList(participants: participants) }.accessibilityIdentifier("RightSidebar.workspaceCollaborators")
    }
}
