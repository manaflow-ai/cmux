#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

extension WorkspaceDetailView {
    func workspaceNavigationBar<Content: View>(content: Content) -> some View {
        WorkspaceNavigationBar(
            title: AnyView(workspaceTitleMenu()),
            content: AnyView(content),
            backgroundColor: UIColor(store.activeTerminalTheme.terminalBackgroundColor),
            scrollEdgeGlass: terminalScrollEdgeGlassActive,
            leadingItems: navigationBarLeadingItems,
            trailingItems: navigationBarTrailingItems
        )
        // The navigation controller manages the status bar, navigation bar,
        // and landscape margins as one native container.
        // The terminal owns the bottom keyboard dock and needs the controller
        // to retain the full window height. UIKit will otherwise size the
        // representable to the visible area above the software keyboard,
        // moving the dock and keyboard shortcut row upward in landscape.
        .ignoresSafeArea(.container, edges: [.top, .leading, .trailing, .bottom])
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
                AltScreenNoticeButton(
                    dismissNotice: { displaySettings.showAltScreenNotice = false },
                    foregroundColor: .primary
                )
            )))
        }
        if workspaceChangesAreAvailable {
            items.append(.init(id: .changes, content: AnyView(
                WorkspaceChangesToolbarButton(
                    chip: workspaceChangesChip,
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    action: openWorkspaceChanges
                )
                .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
            )))
        }
        items.append(.init(id: .terminals, content: AnyView(terminalPickerToolbarButton)))
        return items
    }
}
#endif
