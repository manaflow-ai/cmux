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
        expectedPID: Int32?
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
        expectedPID: Int32?
    ) {
        agentLifecycleCall = (
            target,
            key,
            lifecycleRawValue,
            panelID,
            sessionID,
            startsNewOccupant,
            expectedPIDKey,
            expectedPID
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
