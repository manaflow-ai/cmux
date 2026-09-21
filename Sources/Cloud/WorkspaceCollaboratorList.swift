import SwiftUI

/// Names and avatars shown when the compact collaborator strip is expanded.
struct WorkspaceCollaboratorList: View {
    let workspaceScope: String?
    let collaborators: [WorkspacePresenceParticipant]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "rightSidebar.presence.title", defaultValue: "Viewing this workspace"))
                .font(.headline)
            if workspaceScope == nil {
                Text(String(localized: "rightSidebar.presence.localOnlyHelp", defaultValue: "This local workspace is visible only on this Mac"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if collaborators.isEmpty {
                Text(String(localized: "rightSidebar.presence.onlyYouHelp", defaultValue: "No other collaborators are viewing this workspace"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(collaborators) { participant in
                    WorkspaceCollaboratorRow(participant: participant)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
        .accessibilityIdentifier("RightSidebar.workspaceCollaboratorList")
    }
}
