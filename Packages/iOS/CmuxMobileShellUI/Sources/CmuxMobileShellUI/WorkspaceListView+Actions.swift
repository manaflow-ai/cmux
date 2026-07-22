import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

extension WorkspaceListView {
    var newWorkspaceButton: WorkspaceListNewWorkspaceMenu {
        WorkspaceListNewWorkspaceMenu(
            value: WorkspaceListNewWorkspaceMenuValue(
                canCreate: canCreateWorkspaceForMacSelection,
                canCreateGroup: createWorkspaceGroup != nil
            ),
            actions: WorkspaceListNewWorkspaceMenuActions(
                createWorkspace: createWorkspace,
                createWorkspaceGroup: createWorkspaceGroup
            )
        )
    }

    @discardableResult
    func prepareWorkspaceSelectionFromList() -> Task<Void, Never>? {
        #if os(iOS)
        return cancelMacTitlePickerSwitch()
        #else
        return nil
        #endif
    }

    @discardableResult
    func selectWorkspaceFromList(_ id: CmuxMobileShellModel.MobileWorkspacePreview.ID) -> Task<Void, Never>? {
        invalidateDeferredWorkspaceSelection()
        let selectionGeneration = deferredWorkspaceSelectionGeneration
        guard let cancelTask = prepareWorkspaceSelectionFromList() else {
            selectWorkspace(id)
            return nil
        }
        let task = Task { @MainActor in
            await cancelTask.value
            guard !Task.isCancelled,
                  deferredWorkspaceSelectionGeneration == selectionGeneration else { return }
            selectWorkspace(id)
        }
        return task
    }

    func invalidateDeferredWorkspaceSelection() {
        deferredWorkspaceSelectionGeneration &+= 1
    }

    var requestWorkspaceClose: ((CmuxMobileShellModel.MobileWorkspacePreview.ID) -> Void)? {
        guard closeWorkspace != nil else {
            return nil
        }
        return { workspaceID in
            workspacePendingCloseID = workspaceID
        }
    }

    #if os(iOS)
    var requestWorkspaceRename: ((CmuxMobileShellModel.MobileWorkspacePreview.ID) -> Void)? {
        guard renameWorkspace != nil else { return nil }
        return { workspacePendingRenameID = $0 }
    }

    var requestWorkspaceCustomization: ((CmuxMobileShellModel.MobileWorkspacePreview.ID) -> Void)? {
        guard customizeWorkspace != nil else { return nil }
        return { workspacePendingCustomizationID = $0 }
    }

    var workspaceRenameIsPresented: Binding<Bool> {
        Binding(
            get: { workspacePendingRenameID != nil },
            set: { isPresented in
                if !isPresented {
                    workspacePendingRenameID = nil
                }
            }
        )
    }

    var workspaceCustomizationIsPresented: Binding<Bool> {
        Binding(
            get: { workspacePendingCustomizationID != nil },
            set: { isPresented in
                if !isPresented {
                    workspacePendingCustomizationID = nil
                }
            }
        )
    }

    var workspaceCloseConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { workspacePendingCloseID != nil },
            set: { isPresented in
                if !isPresented {
                    workspacePendingCloseID = nil
                }
            }
        )
    }
    #endif

    func closeConfirmationBinding(for workspaceID: CmuxMobileShellModel.MobileWorkspacePreview.ID) -> Binding<Bool> {
        Binding(
            get: { workspacePendingCloseID == workspaceID },
            set: { isPresented in
                if isPresented {
                    workspacePendingCloseID = workspaceID
                } else if workspacePendingCloseID == workspaceID {
                    workspacePendingCloseID = nil
                }
            }
        )
    }

    func confirmCloseWorkspace() {
        guard let workspaceID = workspacePendingCloseID else {
            return
        }
        workspacePendingCloseID = nil
        closeWorkspace?(workspaceID)
    }
}
