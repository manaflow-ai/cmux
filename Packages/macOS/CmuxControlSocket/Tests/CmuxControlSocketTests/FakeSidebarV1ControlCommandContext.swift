import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSidebarV1ControlCommandContext: ControlCommandContext {
    var workspaceLoadingResult: ControlSidebarWorkspaceLoadingState?
    var workspaceLoadingCall: (tabArg: String?, key: String, on: Bool)?
    nonisolated(unsafe) var statusClearCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?
    )?
    nonisolated(unsafe) var statusUpsertCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    )?
    nonisolated(unsafe) var agentLifecycleCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    )?
    nonisolated(unsafe) var agentPIDClearCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    )?
    nonisolated(unsafe) var agentPIDRecordCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    )?

    nonisolated func controlSidebarScheduleStatusUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: ControlSidebarMetadataFormat,
        panelID: UUID?,
        pid: Int32?,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    ) {
        statusUpsertCall = (target, key, panelID, runtimeKey, runtimeGeneration)
    }

    nonisolated func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        panelID: UUID?,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    ) {
        agentPIDRecordCall = (target, key, panelID, runtimeKey, runtimeGeneration)
    }

    nonisolated func controlSidebarParseAgentLifecycle(_ raw: String) -> String? {
        raw == "running" ? raw : nil
    }

    nonisolated func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        true
    }

    nonisolated func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    ) {
        agentLifecycleCall = (target, key, panelID, runtimeKey, runtimeGeneration)
    }

    nonisolated(unsafe) var shellStateCall: (
        scope: ControlSidebarPanelScope,
        stateRawValue: String
    )?

    nonisolated func controlSurfaceParseShellActivityState(
        _ rawState: String
    ) -> String? {
        switch rawState {
        case "prompt": "promptIdle"
        case "running": "commandRunning"
        default: nil
        }
    }

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
        requireOwnedKey: Bool,
        runtimeKey: String?,
        runtimeGeneration: TimeInterval?
    ) {
        agentPIDClearCall = (
            target,
            key,
            panelID,
            clearStatus,
            requireOwnedKey,
            runtimeKey,
            runtimeGeneration
        )
    }

    nonisolated func controlSidebarScheduleScopedShellState(
        scope: ControlSidebarPanelScope,
        stateRawValue: String
    ) {
        shellStateCall = (scope, stateRawValue)
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
