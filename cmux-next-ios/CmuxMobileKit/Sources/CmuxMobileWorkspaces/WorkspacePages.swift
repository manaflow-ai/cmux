#if os(iOS)
import CmuxMobileModel
import SwiftUI

/// The pages pushed over a workspace (swipe back returns): Search Agent Chats (the Mac's chats),
/// its Screens, its Panes and a tab group's actions (`WorkspaceRoute`), and Fork Conversation…'s
/// question of where the copy of the chat opens (the Mac's fork destinations). Kept apart from
/// `WorkspaceScreen.body`, whose modifier chain is long enough for the type checker already.
struct WorkspacePages: ViewModifier {
    let source: WorkspaceTabsSource

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: Binding(get: { source.showsAgentChats }, set: { source.showsAgentChats = $0 })) {
                AgentChatsScreen(source: source)
            }
            .navigationDestination(item: Binding(get: { source.route }, set: { source.route = $0 })) { route in
                page(route)
            }
            .confirmationDialog("Fork Conversation", isPresented: Binding(
                get: { source.forkingTab != nil },
                set: { shown in if !shown { source.forkingTab = nil } }
            ), titleVisibility: .visible, presenting: source.forkingTab) { tab in
                ForEach(ChatForkDestination.allCases) { destination in
                    Button(destination.title) { Task { await source.fork(tab.id, to: destination) } }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    @ViewBuilder private func page(_ route: WorkspaceTabsSource.WorkspaceRoute) -> some View {
        switch route {
        case .screens: ScreensPage(source: source)
        case .panes: PanesScreen(source: source)
        case .tabGroup(let group): TabGroupPage(source: source, groupID: group)
        }
    }
}
#endif
