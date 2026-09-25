#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

extension WorkspaceDetailView {
    func workspaceNavigationBar<Content: View>(content: Content) -> some View {
        content
            .navigationTitle(systemNavigationTitle)
            .mobileTerminalNavigationChrome(
                theme: store.activeTerminalTheme,
                scrollEdgeGlass: terminalScrollEdgeGlassActive
            )
            .mobileNavigationContainerBackground(store.activeTerminalTheme.terminalBackgroundColor)
            .mobilePinnedNavigationBar()
            .background {
                WorkspaceNavigationBar(
                    title: AnyView(workspaceTitleMenu()),
                    leadingItems: navigationBarLeadingItems,
                    trailingItems: navigationBarTrailingItems
                )
            }
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
            items.append(.init(id: .overflow, content: AnyView(workspaceOverflowToolbarButton)))
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
        items.append(.init(terminals: terminalPickerMenuValue(liveTitles: true), actions: terminalPickerMenuActions))
        return items
    }

    private var workspaceOverflowToolbarButton: some View {
        Menu {
            if workspaceChangesAreAvailable {
                Button("Changes", action: openWorkspaceChanges)
                    .accessibilityIdentifier("MobileChangesButton")
            }
            terminalPickerToolbarButton
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("OverflowBarButtonItem")
    }
}
#endif
