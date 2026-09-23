#if os(iOS)
import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
    var workspaceNavigationBar: some View {
        WorkspaceNavigationBar(
            title: AnyView(workspaceTitleMenu()),
            leadingItems: navigationBarLeadingItems,
            trailingItems: navigationBarTrailingItems
        )
        .background {
            store.activeTerminalTheme.terminalBackgroundColor
                .ignoresSafeArea(edges: .top)
        }
        .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
    }

    private var navigationBarLeadingItems: [WorkspaceNavigationBar.Item] {
        var items: [WorkspaceNavigationBar.Item] = []
        if showsSidebarToggle, let toggleSidebar {
            items.append(.init(id: .sidebar, content: AnyView(
                WorkspaceSidebarToggleButton(action: toggleSidebar)
            )))
        }
        if backButtonConfiguration != nil {
            items.append(.init(id: .back, content: AnyView(workspaceBackToolbarButton)))
        }
        return items
    }

    private var navigationBarTrailingItems: [WorkspaceNavigationBar.Item] {
        let cluster = HStack(spacing: 15) {
            if altScreenNoticeIsVisible {
                AltScreenNoticeButton { displaySettings.showAltScreenNotice = false }
                    .frame(width: 41, height: 36)
            }
            if workspaceChangesAreAvailable {
                WorkspaceChangesToolbarButton(
                    chip: workspaceChangesChip,
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    action: openWorkspaceChanges
                )
                .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
                .frame(width: 55, height: 36)
            }
            terminalPickerToolbarButton
                .frame(width: 42, height: 36)
        }
        .buttonStyle(.plain)
        .frame(height: 44)

        // Keep the trailing controls in one native bar item. SwiftUI's base
        // toolbar presents this same HStack as one glass island, and a single
        // UIKit item lets UINavigationBar reserve its complete width before
        // compressing the title.
        return [.init(id: .trailingCluster, content: AnyView(cluster))]
    }
}
#endif
