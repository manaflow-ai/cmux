#if DEBUG
import SwiftUI

/// DEBUG ONLY: variant 1: the Chief is the sidebar's first thread with its subagents under it; other Chiefs, the
/// group chat and the DM are ordinary threads above the workspaces; the picked thread (the Chief) fills the page.
struct ChiefNoHomeThreadsVariant: View {
    let fixture: ChiefNoHomeFixture

    var body: some View {
        HStack(spacing: 0) {
            ChiefNoHomeSidebar {
                ChiefNoHomeThreadRow(thread: fixture.chief, selected: true)
                ForEach(fixture.subagents) { ChiefNoHomeThreadRow(thread: $0, indent: 18, compact: true) }
                ChiefNoHomeSectionHeader(title: "Threads")
                ForEach(fixture.chats) { ChiefNoHomeThreadRow(thread: $0) }
                ChiefNoHomeSectionHeader(title: "Workspaces")
                ForEach(fixture.workspaces) { ChiefNoHomeWorkspaceRow(workspace: $0) }
            }
            Divider()
            ChiefNoHomeChatView(thread: fixture.chief, fixture: fixture)
        }
    }
}
#endif
