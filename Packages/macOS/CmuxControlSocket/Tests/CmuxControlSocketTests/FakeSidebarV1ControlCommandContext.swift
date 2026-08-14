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
        requireOwnedKey: Bool
    )?
    // The command seam records synchronously; every read and reset stays in this suite's MainActor tests.
    nonisolated(unsafe) var agentLifecycleCall: (
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?,
        promptBoundary: Bool,
        normalCompletion: Bool
    )?
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
        requireOwnedKey: Bool
    ) {
        agentPIDClearCall = (target, key, panelID, clearStatus, requireOwnedKey)
    }

    nonisolated func controlSidebarParseAgentLifecycle(_ raw: String) -> String? {
        ["unknown", "running", "idle", "needsInput"].contains(raw) ? raw : nil
    }

    nonisolated func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        key == "codex"
    }

    nonisolated func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?,
        promptBoundary: Bool,
        normalCompletion: Bool
    ) {
        agentLifecycleCall = (target, key, lifecycleRawValue, panelID, promptBoundary, normalCompletion)
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
