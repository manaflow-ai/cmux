#if os(iOS)
import SwiftUI

struct MobilePrimaryWorkspaceSearchHost<Content: View>: View {
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator
    let taskComposerAction: (() -> Void)?
    let content: (String) -> Content

    init(
        searchCoordinator: MobilePrimarySearchCoordinator,
        taskComposerAction: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.searchCoordinator = searchCoordinator
        self.taskComposerAction = taskComposerAction
        self.content = content
    }

    var body: some View {
        WorkspaceListSearchHost(
            searchText: $searchCoordinator.workspaces,
            taskComposerAction: taskComposerAction,
            content: content
        )
    }
}

struct NotificationFeedSearchProjectionSync: View {
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator
    let projection: NotificationFeedProjection

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: searchCoordinator.notifications, initial: true) { _, searchText in
                projection.searchText = searchText
            }
    }
}
#endif
