import CmuxWorkspaces
import Foundation

extension Workspace {
    func logSessionRestoreTerminalPanelBinding(
        snapshot: SessionPanelSnapshot,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        approvedBinding: SurfaceResumeBindingSnapshot?,
        bindingLaunch: SurfaceResumeStartupLaunch?,
        agentLaunch: SurfaceResumeStartupLaunch?,
        startupCommand: String?,
        startupInput: String?
    ) {
        var fields = sessionRestoreLogFields(snapshot: snapshot)
        fields["binding"] = resumeBinding == nil ? "missing" : "found"
        fields["approved"] = approvedBinding == nil ? "0" : "1"
        fields["launch"] = sessionRestoreLaunchKind(bindingLaunch: bindingLaunch, agentLaunch: agentLaunch)
        fields["resumeCommandPlanned"] = sessionRestoreHasPlannedCommandLaunch(
            bindingLaunch: bindingLaunch,
            agentLaunch: agentLaunch
        ) ? "1" : "0"
        fields["startupPlan"] = sessionRestoreStartupKind(command: startupCommand, input: startupInput)
        if let resumeBinding {
            fields["bindingKind"] = resumeBinding.kind ?? ""
            fields["bindingSource"] = resumeBinding.source ?? ""
            fields["hasCheckpoint"] = resumeBinding.checkpointId == nil ? "0" : "1"
        }
        StartupBreadcrumbLog.appendBatched("app.init.sessionRestore.panel.binding", fields: fields)
    }

    func logSessionRestoreTerminalPanelOutcome(
        snapshot: SessionPanelSnapshot,
        restoredPanelId: UUID?,
        storedBinding: SurfaceResumeBindingSnapshot?,
        startupCommand: String?,
        startupInput: String?,
        outcome: String
    ) {
        var fields = sessionRestoreLogFields(snapshot: snapshot)
        fields["outcome"] = outcome
        fields["restoredPanelId"] = restoredPanelId?.uuidString ?? ""
        fields["storedBinding"] = storedBinding == nil ? "0" : "1"
        fields["startup"] = sessionRestoreStartupKind(command: startupCommand, input: startupInput)
        let didCreatePanel = restoredPanelId != nil
        fields["startupCommandIssued"] = didCreatePanel && startupCommand != nil ? "1" : "0"
        StartupBreadcrumbLog.appendBatched("app.init.sessionRestore.panel.outcome", fields: fields)
    }

    private func sessionRestoreLogFields(snapshot: SessionPanelSnapshot) -> [String: String] {
        [
            "workspaceId": id.uuidString,
            "snapshotPanelId": snapshot.id.uuidString,
            "stableSurfaceId": snapshot.stableSurfaceId?.uuidString ?? "",
            "type": snapshot.type.rawValue,
        ]
    }

    private func sessionRestoreLaunchKind(
        bindingLaunch: SurfaceResumeStartupLaunch?,
        agentLaunch: SurfaceResumeStartupLaunch?
    ) -> String {
        if let bindingLaunch {
            return bindingLaunch.initialCommand == nil ? "binding.input" : "binding.command"
        }
        if let agentLaunch {
            return agentLaunch.initialCommand == nil ? "agent.input" : "agent.command"
        }
        return "none"
    }

    private func sessionRestoreHasPlannedCommandLaunch(
        bindingLaunch: SurfaceResumeStartupLaunch?,
        agentLaunch: SurfaceResumeStartupLaunch?
    ) -> Bool {
        bindingLaunch?.initialCommand != nil || agentLaunch?.initialCommand != nil
    }

    private func sessionRestoreStartupKind(command: String?, input: String?) -> String {
        if command != nil { return "command" }
        if input != nil { return "input" }
        return "shell"
    }
}
