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
        value: String,
        panelID: UUID?,
        agentMutationGuard: ControlSidebarAgentMutationGuard?
    )?
    nonisolated(unsafe) var agentPIDRecordCall: (
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        panelID: UUID?,
        expectedLifecycleSessionID: String?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?
    )?
    nonisolated(unsafe) var agentPIDClearCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        expectedLifecycleSessionID: String?,
        expectedPID: Int32?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?,
        requireOwnedKey: Bool
    )?
    nonisolated(unsafe) var agentLifecycleCall: (
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?,
        sessionID: String?,
        startsNewOccupant: Bool,
        expectedPIDKey: String?,
        expectedPID: Int32?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?
    )?
    nonisolated(unsafe) var agentLifecycleAccepted = true
    nonisolated(unsafe) var agentLifecycleClearNotifications = true
    nonisolated(unsafe) var agentPIDClearAccepted = true
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
        agentMutationGuard: ControlSidebarAgentMutationGuard?
    ) {
        statusUpsertCall = (target, key, value, panelID, agentMutationGuard)
    }

    nonisolated func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        panelID: UUID?,
        expectedLifecycleSessionID: String?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?
    ) {
        agentPIDRecordCall = (
            target,
            key,
            pid,
            panelID,
            expectedLifecycleSessionID,
            expectedPIDStartSeconds,
            expectedPIDStartMicroseconds
        )
    }

    nonisolated func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        expectedLifecycleSessionID: String?,
        expectedPID: Int32?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?,
        requireOwnedKey: Bool
    ) {
        agentPIDClearCall = (
            target,
            key,
            panelID,
            clearStatus,
            expectedLifecycleSessionID,
            expectedPID,
            expectedPIDStartSeconds,
            expectedPIDStartMicroseconds,
            requireOwnedKey
        )
    }

    nonisolated func controlSidebarClearAgentPIDAndVerifyOwner(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        expectedLifecycleSessionID: String?,
        expectedPID: Int32?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?,
        requireOwnedKey: Bool
    ) -> Bool {
        controlSidebarScheduleAgentPIDClear(
            target: target,
            key: key,
            panelID: panelID,
            clearStatus: clearStatus,
            expectedLifecycleSessionID: expectedLifecycleSessionID,
            expectedPID: expectedPID,
            expectedPIDStartSeconds: expectedPIDStartSeconds,
            expectedPIDStartMicroseconds: expectedPIDStartMicroseconds,
            requireOwnedKey: requireOwnedKey
        )
        return agentPIDClearAccepted
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
        sessionID: String?,
        startsNewOccupant: Bool,
        expectedPIDKey: String?,
        expectedPID: Int32?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?
    ) {
        agentLifecycleCall = (
            target,
            key,
            lifecycleRawValue,
            panelID,
            sessionID,
            startsNewOccupant,
            expectedPIDKey,
            expectedPID,
            expectedPIDStartSeconds,
            expectedPIDStartMicroseconds
        )
    }

    nonisolated func controlSidebarApplyAgentLifecycleAndVerifyOwner(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?,
        sessionID: String?,
        startsNewOccupant: Bool,
        expectedPIDKey: String?,
        expectedPID: Int32?,
        expectedPIDStartSeconds: Int64?,
        expectedPIDStartMicroseconds: Int64?,
        preflightOnly: Bool,
        clearNotifications: Bool
    ) -> Bool {
        agentLifecycleClearNotifications = clearNotifications
        controlSidebarScheduleAgentLifecycle(
            target: target,
            key: key,
            lifecycleRawValue: lifecycleRawValue,
            panelID: panelID,
            sessionID: sessionID,
            startsNewOccupant: startsNewOccupant,
            expectedPIDKey: expectedPIDKey,
            expectedPID: expectedPID,
            expectedPIDStartSeconds: expectedPIDStartSeconds,
            expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
        )
        return agentLifecycleAccepted
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
