#if os(iOS)
import SwiftUI

struct MobilePrimaryWorkspaceSearchHost<Content: View>: View {
    @Bindable var searchTextState: MobilePrimarySearchTextState
    let taskComposerAction: (() -> Void)?
    let content: (String) -> Content

    init(
        searchTextState: MobilePrimarySearchTextState,
        taskComposerAction: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.searchTextState = searchTextState
        self.taskComposerAction = taskComposerAction
        self.content = content
    }

    var body: some View {
        WorkspaceListSearchHost(
            searchText: $searchTextState.workspaces,
            taskComposerAction: taskComposerAction,
            content: content
        )
    }
}

struct NotificationFeedSearchProjectionSync: View {
    @Bindable var searchTextState: MobilePrimarySearchTextState
    let projection: NotificationFeedProjection

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: searchTextState.notifications, initial: true) { _, searchText in
                projection.searchText = searchText
            }
    }
}
#endif
