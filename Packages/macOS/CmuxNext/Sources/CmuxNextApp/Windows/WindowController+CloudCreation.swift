import AppKit

// The New Cloud Workspace progress in a window's content area (cx-lu8f).
extension WindowController {
    /// What the creation observation re-runs on: the shown creation, and
    /// whether its workspace is mirrored (then the window shows it).
    static func creationKey(_ state: WindowState, _ cloud: CloudService, _ machines: MachineRegistry) -> String {
        guard let id = state.cloudCreation else { return "" }
        guard let creation = cloud.creations.creation(id) else { return "gone" }
        let mirrored = creation.workspaceID.map { machines.workspace(id: $0) != nil } ?? false
        return "\(id):\(mirrored)"
    }

    /// Shows the window's Cloud creation (cx-lu8f) until its workspace is
    /// mirrored; then the window shows that workspace. False when there is
    /// none to show.
    func showCreation() -> Bool {
        guard let id = state.cloudCreation else { return false }
        guard let creation = services.cloud.creations.creation(id) else {
            state.cloudCreation = nil
            return false
        }
        if let opened = creation.workspaceID, services.machines.workspace(id: opened) != nil {
            state.cloudCreation = nil
            if state.workspaceID != opened { services.windows.select(opened, in: state) }
            return false
        }
        // The view in the content area is the creation's own record (no stored property).
        if let shown = root.content as? CloudMachineProgressView, shown.creation === creation { return true }
        parkContentForPage()
        let view = CloudMachineProgressView(creation: creation, actions: CloudMachineProgressView.Actions(
            retry: { [weak self] creation in
                guard let self else { return }
                CloudHandlers.creationFlow(AppActionContext(services: self.services)).retry(creation)
            },
            dismiss: { [weak self] creation in
                guard let self else { return }
                CloudHandlers.creationFlow(AppActionContext(services: self.services)).dismiss(creation, in: self.state)
            }))
        root.show(view)
        // Keys typed before the terminal exists land on the view (it says so), not on a hidden pane.
        window?.makeFirstResponder(view)
        themeScope.show(nil)
        root.titlebar.title = CloudStrings.newCloudWorkspaceTitle
        services.windows.recordSaver.stateDidChange(state)
        return true
    }
}
