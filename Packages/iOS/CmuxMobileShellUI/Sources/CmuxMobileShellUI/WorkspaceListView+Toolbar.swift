import SwiftUI

extension WorkspaceListView {
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
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            WorkspaceListFilterMenu(filter: $filter, machines: filterMachines)
                            if canCreateWorkspace {
                                newWorkspaceButton
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
                        WorkspaceListFilterMenu(filter: $filter, machines: filterMachines)
                        if canCreateWorkspace {
                            newWorkspaceButton
                        }
                    }
                }
        #endif
    }
}
