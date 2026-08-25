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
        return { workspaceID in
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
            workspaceRenameDraft = workspace.name
            workspacePendingRenameID = workspaceID
        }
    }

    var requestWorkspaceCustomization: ((CmuxMobileShellModel.MobileWorkspacePreview.ID) -> Void)? {
        guard customizeWorkspace != nil else { return nil }
        return { workspaceID in
            workspaceCustomizationPresentation.present {
                workspacePendingCustomizationID = workspaceID
            }
        }
    }

    var requestWorkspaceGroupRename: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        guard renameWorkspaceGroup != nil else { return nil }
        return { groupID in
            guard let group = groups.first(where: { $0.id == groupID }) else { return }
            workspaceGroupRenameDraft = group.name
            workspaceGroupPendingRenameID = groupID
        }
    }

    var requestWorkspaceGroupUngroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        guard ungroupWorkspaceGroup != nil else { return nil }
        return { groupID in
            workspaceGroupDestructiveRequest.enqueue(groupID: groupID, action: .ungroup)
        }
    }

    var requestWorkspaceGroupDelete: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        guard deleteWorkspaceGroup != nil else { return nil }
        return { groupID in
            workspaceGroupDestructiveRequest.enqueue(groupID: groupID, action: .delete)
        }
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

    var workspaceCustomizationPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceList(.customization),
            fallback: $isWorkspaceCustomizationPresented
        )
    }

    var workspaceChangesPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceList(.changes),
            fallback: $isWorkspaceChangesPresented
        )
    }

    var workspaceGroupRenameIsPresented: Binding<Bool> {
        Binding(
            get: { workspaceGroupPendingRenameID != nil },
            set: { isPresented in
                if !isPresented {
                    workspaceGroupPendingRenameID = nil
                }
            }
        )
    }

    var workspaceGroupDestructiveConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: {
                workspaceGroupPendingDestructiveID != nil
                    && workspaceGroupPendingDestructiveAction != nil
            },
            set: { isPresented in
                if !isPresented {
                    clearWorkspaceGroupDestructiveRequest()
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

    var workspaceGroupDestructiveDialogTitle: String {
        switch workspaceGroupPendingDestructiveAction {
        case .ungroup:
            L10n.string("mobile.workspaceGroup.ungroup.confirmTitle", defaultValue: "Ungroup Group?")
        case .delete:
            L10n.string("mobile.workspaceGroup.delete.confirmTitle", defaultValue: "Delete Group?")
        case nil:
            ""
        }
    }

    var workspaceGroupDestructiveDialogMessage: String {
        switch workspaceGroupPendingDestructiveAction {
        case .ungroup:
            L10n.string(
                "mobile.workspaceGroup.ungroup.confirmMessage",
                defaultValue: "This will dissolve the group on your Mac and keep its workspaces."
            )
        case .delete:
            L10n.string(
                "mobile.workspaceGroup.delete.confirmMessage",
                defaultValue: "This will delete the group and close its workspaces on your Mac."
            )
        case nil:
            ""
        }
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

    func confirmWorkspaceGroupDestructiveAction() {
        guard let request = workspaceGroupDestructiveRequest.consume() else {
            return
        }
        switch request.action {
        case .ungroup:
            ungroupWorkspaceGroup?(request.groupID)
        case .delete:
            deleteWorkspaceGroup?(request.groupID)
        }
    }

    func clearWorkspaceGroupDestructiveRequest() {
        workspaceGroupDestructiveRequest.clear()
    }
}
