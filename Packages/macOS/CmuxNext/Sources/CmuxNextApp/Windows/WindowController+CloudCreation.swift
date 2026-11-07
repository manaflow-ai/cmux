import AppKit
import CmuxNextCloudUI

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
        if let shown = root.content as? CloudProgressHost, shown.source === creation { return true }
        parkContentForPage()
        let view = CloudProgressHost(source: creation, actions: .progress(
            retry: { [weak self, weak creation] in
                guard let self, let creation else { return }
                CloudHandlers.creationFlow(AppActionContext(services: self.services)).retry(creation)
            },
            dismiss: { [weak self, weak creation] in
                guard let self, let creation else { return }
                CloudHandlers.creationFlow(AppActionContext(services: self.services)).dismiss(creation, in: self.state)
            }))
        creation.progressHost = view
        root.show(view)
        // Keys typed before the terminal exists land on the page (it says so), not on a hidden pane.
        window?.makeFirstResponder(view)
        themeScope.show(nil)
        root.titlebar.title = CloudStrings.newCloudWorkspaceTitle
        services.windows.recordSaver.stateDidChange(state)
        return true
    }
}

/// The progress page reads a creation as plain values (CloudUI knows no App type); its actions carry the App's copy.
extension CloudMachineCreation: CloudProgressSource {
    var progressStage: String { stage.name }
    var progressStepIndex: Int? { stage.stepIndex }
    var progressSteps: [String] { CloudMachineStage.steps.map(\.name) }
    var progressFailure: String? { stage.failure }
    var progressIdle: Bool { stage == .paused(idle: true) }
    var progressMachine: String? { machineTitle }
    var progressFinished: Bool { stage.isFinished }
    func progressElapsed() -> Duration { elapsed() }
    var progressChangeKey: String { "\(stage)|\(machineTitle ?? "")|\(workspaceID ?? "")" }
}

extension CloudProgressPageProvider.Actions {
    static func progress(retry: @escaping @MainActor () -> Void, dismiss: @escaping @MainActor () -> Void) -> Self {
        Self(retry: retry, dismiss: dismiss, copy: CloudPresenter.copy, personOnlyMessage: RefusalStrings.personOnlyFromPage)
    }
}
