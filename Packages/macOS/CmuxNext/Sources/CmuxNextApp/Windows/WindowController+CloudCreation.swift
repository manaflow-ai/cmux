import AppKit
import CmuxNextActions
import CmuxNextCloudUI

// The New Cloud Workspace progress in a window's content area (cx-lu8f), and a kept Cloud
// workspace that is not connected (P-AUSTIN B7).
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

    /// Shows kept Cloud workspace `id` as not connected (P-AUSTIN B7) in place of its content, never a
    /// blank pane: the card, or with Debug Settings `cloud.absentCompact` its one-line form. While it only
    /// connects and the window shows content, that content stays (a redial never flashes).
    func showAbsent(_ id: String, _ absence: CloudWorkspaceAbsence) {
        if state.workspaceID != id { state.workspaceID = id }
        if absence == .connecting, content != nil { return }
        let style: CloudWorkspaceAbsentView.Style = CloudTunables.absentCompact.value ? .compact : .card
        let view = (root.content as? CloudWorkspaceAbsentView).flatMap { $0.style == style ? $0 : nil }
            ?? CloudWorkspaceAbsentView(style: style) { [weak self] action in self?.performAbsent(action) }
        let title = sidebar.absentRowTitle(id)
        view.show(workspaceID: id, title: title, machine: sidebar.absentMachineName(id), absence: absence)
        if root.content !== view {
            parkContentForPage()
            root.show(view)
            themeScope.show(nil)
        }
        titleObservation?.cancel()
        root.titlebar.title = title
        services.windows.absentContentDidAppear(self)
    }

    /// The kept Cloud workspace this window shows as not connected, and why (P-AUSTIN B7); nil otherwise.
    var shownCloudAbsence: (workspaceID: String, absence: CloudWorkspaceAbsence)? {
        (root.content as? CloudWorkspaceAbsentView).map { ($0.workspaceID, $0.absence) }
    }

    /// Sign In, or Resume Machine on the shown workspace's machine: the same actions as the palette's.
    private func performAbsent(_ action: CloudWorkspaceAbsence.Action) {
        switch action {
        case .signIn: _ = services.registry.perform("palette.auth.signIn", invocation: ActionInvocation(origin: .user))
        case .resume:
            guard let id = state.workspaceID, let machine = services.windows.seenMachine[id] else { return }
            _ = services.registry.perform("cloudResumeMachine", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine), origin: .user))
        }
    }
}
