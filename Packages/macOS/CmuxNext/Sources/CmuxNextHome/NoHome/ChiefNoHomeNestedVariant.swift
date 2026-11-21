#if DEBUG
import SwiftUI

/// DEBUG ONLY: variant 2: the Chief is pinned on top; each workspace lists the agent chats and Chief subagents that
/// work in it; other Chiefs, the group chat and the DM sit in the same Recent list as the workspaces. The stage shows
/// the picked workspace with its threads as tabs.
struct ChiefNoHomeNestedVariant: View {
    let fixture: ChiefNoHomeFixture

    var body: some View {
        HStack(spacing: 0) {
            ChiefNoHomeSidebar {
                ChiefNoHomeThreadRow(thread: fixture.chief)
                ChiefNoHomeSectionHeader(title: "Recent")
                ForEach(Array(fixture.workspaces.prefix(2))) { workspace in
                    ChiefNoHomeWorkspaceRow(workspace: workspace, selected: workspace.id == "ws-sidebar")
                    ForEach(fixture.threads(in: workspace.id)) { ChiefNoHomeThreadRow(thread: $0, indent: 18, compact: true) }
                }
                ForEach(Array(fixture.chats.prefix(2))) { ChiefNoHomeThreadRow(thread: $0) }
                ForEach(Array(fixture.workspaces.dropFirst(2))) { workspace in
                    ChiefNoHomeWorkspaceRow(workspace: workspace)
                    ForEach(fixture.threads(in: workspace.id)) { ChiefNoHomeThreadRow(thread: $0, indent: 18, compact: true) }
                }
                ForEach(Array(fixture.chats.dropFirst(2))) { ChiefNoHomeThreadRow(thread: $0) }
            }
            Divider()
            ChiefNoHomeStageView(workspace: fixture.workspaces[0], threads: fixture.threads(in: "ws-sidebar"))
        }
    }
}
#endif
