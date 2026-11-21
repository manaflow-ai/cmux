#if DEBUG
import SwiftUI

/// DEBUG ONLY: variant 3 (David Beyer: "an option to open Chief in a dedicated side panel"): the sidebar has the
/// workspaces and the threads, the workspace keeps the stage, and the Chief is a side panel at the right edge; other
/// Chiefs and chats are one Threads switcher in the panel's header, never a panel of their own.
struct ChiefNoHomeSidePanelVariant: View {
    let fixture: ChiefNoHomeFixture

    var body: some View {
        HStack(spacing: 0) {
            ChiefNoHomeSidebar {
                ChiefNoHomeSectionHeader(title: "Workspaces")
                ForEach(fixture.workspaces) { ChiefNoHomeWorkspaceRow(workspace: $0, selected: $0.id == "ws-sidebar") }
                ChiefNoHomeSectionHeader(title: "Threads")
                ChiefNoHomeThreadRow(thread: fixture.chief, compact: true)
                ForEach(fixture.chats) { ChiefNoHomeThreadRow(thread: $0, compact: true) }
            }
            Divider()
            ChiefNoHomeStageView(workspace: fixture.workspaces[0], threads: fixture.threads(in: "ws-sidebar"))
            Divider()
            ChiefNoHomeChatView(thread: fixture.chief, fixture: fixture, switcher: true, narrow: true)
                .frame(width: 380)
        }
    }
}
#endif
