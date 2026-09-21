import SwiftUI

/// Compact, discoverable collaborator chrome for the active right-sidebar
/// workspace. The popover keeps names readable when the avatar stack is full.
struct WorkspaceCollaboratorsView: View {
    let workspaceScope: String?
    @Bindable var presence: WorkspacePresenceController
    @State private var isPopoverPresented = false

    private var collaborators: [WorkspacePresenceParticipant] {
        presence.collaborators(for: workspaceScope)
    }

    var body: some View {
        Button {
            guard workspaceScope != nil else { return }
            isPopoverPresented.toggle()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .disabled(workspaceScope == nil)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("RightSidebar.workspaceCollaborators")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            WorkspaceCollaboratorList(
                workspaceScope: workspaceScope,
                collaborators: collaborators
            )
        }
    }

    @ViewBuilder
    private var label: some View {
        if workspaceScope == nil {
            Label(
                String(localized: "rightSidebar.presence.localOnly", defaultValue: "Local only"),
                systemImage: "person"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if !presence.isAvailable(for: workspaceScope) {
            Label(
                String(localized: "rightSidebar.presence.unavailable", defaultValue: "Presence unavailable"),
                systemImage: "person.2.slash"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if collaborators.isEmpty {
            Label(
                String(localized: "rightSidebar.presence.onlyYou", defaultValue: "Only you"),
                systemImage: "person"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            let layout = WorkspacePresencePolicy.avatarLayout(participants: collaborators)
            HStack(spacing: 4) {
                HStack(spacing: -5) {
                    ForEach(layout.visible) { participant in
                        WorkspaceCollaboratorAvatar(participant: participant, size: 19)
                    }
                }
                if layout.overflowCount > 0 {
                    Text("+\(layout.overflowCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
    }

    private var helpText: String {
        if workspaceScope == nil {
            return String(localized: "rightSidebar.presence.localOnlyHelp", defaultValue: "This local workspace is visible only on this Mac")
        }
        if collaborators.isEmpty {
            return String(localized: "rightSidebar.presence.onlyYouHelp", defaultValue: "No other collaborators are viewing this workspace")
        }
        return String(localized: "rightSidebar.presence.collaboratorsHelp", defaultValue: "Collaborators are viewing this workspace")
    }

    private var accessibilityText: String {
        if workspaceScope == nil {
            return String(localized: "rightSidebar.presence.localOnly", defaultValue: "Local only")
        }
        if collaborators.isEmpty {
            return String(localized: "rightSidebar.presence.onlyYou", defaultValue: "Only you")
        }
        return String(localized: "rightSidebar.presence.collaboratorsAccessibility", defaultValue: "Collaborators are viewing")
    }
}

private struct WorkspaceCollaboratorAvatar: View {
    let participant: WorkspacePresenceParticipant
    let size: CGFloat

    var body: some View {
        StackAccountAvatarView(
            avatarURL: participant.avatarURL,
            displayName: participant.displayName ?? String(localized: "rightSidebar.presence.anonymous", defaultValue: "Anonymous collaborator"),
            email: "",
            size: size
        )
        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
        .help(participant.displayName ?? String(localized: "rightSidebar.presence.anonymous", defaultValue: "Anonymous collaborator"))
    }
}
