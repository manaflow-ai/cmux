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
        var items: [WorkspaceNavigationBar.Item] = []
        if altScreenNoticeIsVisible {
            items.append(.init(id: .alternateScreen, content: AnyView(
                AltScreenNoticeButton { displaySettings.showAltScreenNotice = false }
            )))
        }
        if workspaceChangesAreAvailable {
            items.append(.init(id: .changes, content: AnyView(
                WorkspaceChangesToolbarButton(
                    chip: workspaceChangesChip,
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    action: openWorkspaceChanges
                )
            )))
        }
        items.append(.init(id: .terminals, content: AnyView(terminalPickerToolbarButton)))
        return items
    }
}
#endif
