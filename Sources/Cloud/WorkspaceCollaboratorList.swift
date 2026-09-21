import SwiftUI

struct WorkspaceCollaboratorList: View {
    let participants: [WorkspacePresenceParticipant]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "rightSidebar.presence.title", defaultValue: "Viewing this workspace")).font(.headline)
            if participants.isEmpty {
                Text(String(localized: "rightSidebar.presence.onlyYouHelp", defaultValue: "No other collaborators are viewing this workspace")).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(participants) { WorkspaceCollaboratorRow(participant: $0) }
            }
        }.padding(12).frame(minWidth: 220, alignment: .leading)
    }
}
