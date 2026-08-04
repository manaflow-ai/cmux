import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSidebarV1ControlCommandContext: ControlCommandContext {
    nonisolated(unsafe) var requiresAgentProcessGeneration = true
    var workspaceLoadingResult: ControlSidebarWorkspaceLoadingState?
    var workspaceLoadingCall: (tabArg: String?, key: String, on: Bool)?
    nonisolated(unsafe) var statusClearCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?
    )?
    nonisolated(unsafe) var agentPIDClearCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool
    )?
    nonisolated(unsafe) var agentPIDRecordCall: (
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        processGeneration: ControlSidebarAgentProcessGeneration?,
        panelID: UUID?
    )?
    nonisolated(unsafe) var agentLifecycleCall: (
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        processGeneration: ControlSidebarAgentProcessGeneration?,
        panelID: UUID?
    )?

    nonisolated func controlSidebarScheduleStatusClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?
    ) {
        statusClearCall = (target, key, panelID)
    }

    nonisolated func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool
    ) {
        agentPIDClearCall = (target, key, panelID, clearStatus, requireOwnedKey)
    }

    nonisolated func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        processGeneration: ControlSidebarAgentProcessGeneration?,
        panelID: UUID?
    ) {
        agentPIDRecordCall = (
            target,
            key,
            pid,
            processGeneration,
            panelID
        )
    }

    nonisolated func controlSidebarParseAgentLifecycle(
        _ raw: String
    ) -> String? {
        ["unknown", "running", "idle", "needsInput"].contains(raw)
            ? raw
            : nil
    }

    nonisolated func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        true
    }

    nonisolated func controlSidebarRequiresAgentProcessGeneration(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        requiresAgentProcessGeneration
    }

    nonisolated func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        processGeneration: ControlSidebarAgentProcessGeneration?,
        panelID: UUID?
    ) {
        agentLifecycleCall = (
            target,
            key,
            lifecycleRawValue,
            processGeneration,
            panelID
        )
    }

    func controlSidebarSetWorkspaceLoading(
        tabArg: String?,
        key: String,
        on: Bool
    ) -> ControlSidebarWorkspaceLoadingState? {
        workspaceLoadingCall = (tabArg, key, on)
        return workspaceLoadingResult
    }
}
