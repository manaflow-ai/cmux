import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

extension WorkspaceListView {
    var newWorkspaceButton: some View {
        Button {
            guard canCreateWorkspaceForMacSelection else { return }
            createWorkspace()
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!canCreateWorkspaceForMacSelection)
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
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
