import CmuxMobileSupport
import SwiftUI

extension WorkspaceListView {
    var workspaceListFilterMenuActions: WorkspaceListFilterMenuActions {
        WorkspaceListFilterMenuActions(
            setReadState: { filter.readState = $0 },
            clearMachines: { filter.machines.removeAll() },
            toggleMachine: { filter.toggleMachine($0) },
            setSortMode: setWorkspaceSortMode
        )
    }

    #if os(iOS)
    /// The sort + filter entry point: one toolbar button opening the Mail-style
    /// view-options card (illustrated sort tiles + read-state rows; computer
    /// selection stays in its dedicated title picker). The icon fills while a
    /// narrowing filter is active, mirroring Mail.
    @ViewBuilder
    func viewOptionsButton() -> some View {
        Button {
            showingViewOptionsPopover = true
        } label: {
            Image(systemName: filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.filter", defaultValue: "Filter"))
        .accessibilityIdentifier("MobileWorkspaceFilterMenu")
        .onAppear {
            // Headless harnesses cannot tap the toolbar; let the layout-preview
            // fixture open the card at launch for screenshot verification.
            #if DEBUG
            if ProcessInfo.processInfo.environment[
                "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_VIEW_OPTIONS"
            ] == "1" {
                showingViewOptionsPopover = true
            }
            #endif
        }
        .popover(isPresented: $showingViewOptionsPopover) {
            WorkspaceListViewOptionsPopover(
                filter: filter,
                sortMode: workspaceSortMenuMode,
                orderMachines: computerOrderSheetMachines,
                saveComputerOrder: setWorkspaceComputerPriority,
                actions: workspaceListFilterMenuActions
            )
        }
    }
    #endif

    @ViewBuilder
    func workspaceListWithToolbar<Content: View>(
        _ content: Content,
        machineSnapshots: WorkspaceMachineSnapshots,
        filterMachines: [WorkspaceFilterMachine]
    ) -> some View {
        #if os(iOS)
            if showsNavigationToolbar {
                content
                    .toolbar {
                        if !usesExternalSharedToolbar {
                            ToolbarItem(id: "workspace-list-settings", placement: .topBarLeading) {
                                settingsMenu
                            }
                            ToolbarItem(id: "workspace-list-title", placement: .principal) {
                                macTitlePicker(machineSnapshots: machineSnapshots)
                            }
                            if showsDevicesButton {
                                ToolbarItem(id: "workspace-list-devices", placement: .topBarLeading) {
                                    devicesButton
                                }
                            }
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if let macUpdateHint, let dismissMacUpdateHint,
                               connectionChrome.showsMacUpdateHintIndicator {
                                MacUpdateHintIndicatorButton(
                                    hint: macUpdateHint,
                                    macDisplayName: macUpdateHintMacName,
                                    dismiss: dismissMacUpdateHint
                                )
                            }
                            viewOptionsButton()
                            if canCreateWorkspace {
                                newWorkspaceButton.equatable()
                            }
                        }
                    }
            } else {
                content
            }
        #else
            content
                .toolbar {
                    ToolbarItemGroup {
                        WorkspaceListFilterMenu(
                            filter: filter,
                            machines: filterMachines,
                            actions: workspaceListFilterMenuActions
                        )
                        .equatable()
                        if canCreateWorkspace {
                            newWorkspaceButton.equatable()
                        }
                    }
                }
        #endif
    }
}
