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

#endif
